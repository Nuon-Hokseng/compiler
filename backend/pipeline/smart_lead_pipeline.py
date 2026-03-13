"""
Smart Lead Pipeline — Unified scrolling + scraping + qualification + follow.

Orchestrates three phases in a single Playwright session:
  Phase 1: Discovery Brain generates search plan (background thread)
           while the browser scrolls normally on the feed.
  Phase 2: Scraper agent visits hashtag pages from the plan, opens
           individual posts, extracts post owners + commenters to build
           a username list.  Interleaved with normal scrolling.
  Phase 3: Qualification loop — scroll normally on feed, 30 % chance
           per scroll to visit the next profile from the list → search
           → scroll profile → extract data → qualify with AI → follow
           if qualified → go back to home → keep scrolling.
"""

import re
import time
import random
import threading
from typing import Callable

from playwright.sync_api import sync_playwright

from browser.scrolling import (
    create_log_function,
    create_stop_checker,
    do_single_scroll,
    try_random_like,
    launch_instagram_browser,
)
from browser.search_engine import perform_search
from browser.hybrid import scroll_on_page, go_back_to_feed, scroll_to_top_and_follow
from browser.launcher import DEFAULT_BROWSER, DEFAULT_HEADLESS
from browser.scraper import (
    is_valid_username,
    USERNAME_PATTERN,
    MAX_POSTS_PER_HASHTAG,
    MAX_COMMENTERS_PER_POST,
    get_delay,
)
# Re-use the sync helpers from scraper_integration (same logic, no duplication)
from browser.scraper_integration import (
    _human_delay_sync,
    _maybe_take_break_sync,
    _extract_post_owner,
    _extract_commenters,
)


# ── Helpers ──────────────────────────────────────────────────────────


def _parse_count(val: str) -> int:
    """Parse follower / following count strings like '1,234' or '12.3K'."""
    val = val.strip().replace(",", "")
    multiplier = 1
    if val.lower().endswith("k"):
        multiplier = 1_000
        val = val[:-1]
    elif val.lower().endswith("m"):
        multiplier = 1_000_000
        val = val[:-1]
    try:
        return int(float(val) * multiplier)
    except (ValueError, TypeError):
        return 0


def _extract_sync_profile_data(page, username: str, log=print) -> dict:
    """
    Extract profile data from the current profile page (sync Playwright).
    Returns a dict suitable for qualification_brain.
    """
    data = {"username": username}

    try:
        # ── Full name from og:title ──
        try:
            og_title = page.get_attribute('meta[property="og:title"]', "content")
            if og_title and "(" in og_title:
                data["full_name"] = og_title.split("(")[0].strip()
            elif og_title:
                data["full_name"] = og_title.split("•")[0].strip()
            else:
                data["full_name"] = ""
        except Exception:
            data["full_name"] = ""

        # ── Bio + follower / following counts from og:description ──
        try:
            og_desc = page.get_attribute('meta[property="og:description"]', "content")
            if og_desc:
                parts = og_desc.split(" - ", 1)
                data["bio"] = parts[1][:300].strip() if len(parts) > 1 else ""

                nums = re.findall(r"([\d,.KkMm]+)\s+(Follower|Following|Post)", og_desc)
                for val, label in nums:
                    parsed = _parse_count(val)
                    if "Follower" in label:
                        data["followers_count"] = parsed
                    elif "Following" in label:
                        data["following_count"] = parsed
            else:
                data["bio"] = ""
        except Exception:
            data["bio"] = ""

        data.setdefault("followers_count", 0)
        data.setdefault("following_count", 0)

        # ── Profile image ──
        try:
            og_img = page.get_attribute('meta[property="og:image"]', "content")
            data["profile_image_url"] = og_img or ""
        except Exception:
            data["profile_image_url"] = ""

        # ── Recent captions from alt text ──
        captions: list[str] = []
        try:
            imgs = page.query_selector_all("article img[alt]")
            for img in imgs[:5]:
                alt = img.get_attribute("alt")
                if alt and len(alt) > 10:
                    captions.append(alt[:300])
        except Exception:
            pass
        data["recent_captions"] = captions
        data["recent_comments"] = []

        # ── Language detection ──
        all_text = " ".join([data.get("bio", ""), data.get("full_name", "")])
        all_text += " ".join(captions)
        jp_chars = len(re.findall(r"[\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FFF]", all_text))
        total = max(len(all_text), 1)
        data["detected_language"] = "ja" if jp_chars / total > 0.1 else "en"

    except Exception as e:
        log(f"    Profile extraction error: {e}")

    return data


# ── Work / lifestyle signal keywords (used by pre-filter) ───────────

WORK_LIFESTYLE_SIGNALS = [
    # English signals
    "ceo", "founder", "coach", "mentor", "entrepreneur", "business",
    "consultant", "freelance", "creator", "artist", "photographer",
    "designer", "developer", "writer", "trainer", "influencer",
    "brand", "shop", "store", "link in bio", "dm for", "bookings",
    "available", "services", "portfolio", "www.", "http", ".com",
    "\U0001f4e7", "\U0001f4e9", "\U0001f4bc", "\U0001f517", "\U0001f447", "\u2b07\ufe0f",
    "collab", "partnership", "work with me", "enquiries", "management",
    # Japanese work/lifestyle signals
    "看護師", "介護", "工場", "運送", "バイト", "副業", "パート",
    "転職", "仕事", "働く", "社会人", "新卒", "正社員", "派遣",
    "車", "ドライブ", "大学", "専門学校", "卒業",
    "稼ぐ", "お金", "収入", "フリーランス",
    "地方", "田舎",
]


def _pre_filter_profile(
    page,
    username: str,
    target_interest: str,
    optional_keywords: list[str] | None = None,
    log=print,
) -> bool:
    """
    Quick profile visit to decide if a commenter is worth qualifying.

    Returns **True** to KEEP the profile (premium candidate).
    Skips (returns False) only when **ALL** of these are true:
      - Bio is empty or very short (< 20 chars)
      - No niche keywords found in bio / recent captions
      - No work / lifestyle signals detected
      - Low followers (< 100) or weak activity
    """
    try:
        page.goto(
            f"https://www.instagram.com/{username}/",
            wait_until="domcontentloaded",
        )
        try:
            page.wait_for_selector(
                'meta[property="og:description"]', timeout=8_000
            )
        except Exception:
            pass
        _human_delay_sync("read_content")

        data = _extract_sync_profile_data(page, username, log)

        bio = data.get("bio", "").strip()
        followers = data.get("followers_count", 0)
        captions = data.get("recent_captions", [])

        # ── Build niche keywords from the user's target interest ──
        niche_keywords: set[str] = set()
        for word in target_interest.lower().split():
            if len(word) > 2:
                niche_keywords.add(word)
        if optional_keywords:
            for kw in optional_keywords:
                for word in kw.lower().split():
                    if len(word) > 2:
                        niche_keywords.add(word)

        all_text = (bio + " " + " ".join(captions)).lower()

        # ── Four criteria ──
        bio_empty = len(bio) < 20
        no_niche = not any(kw in all_text for kw in niche_keywords)
        no_signals = not any(sig in all_text for sig in WORK_LIFESTYLE_SIGNALS)
        low_followers = followers < 100

        # Skip ONLY when ALL four hold
        if bio_empty and no_niche and no_signals and low_followers:
            log(
                f"      \u274c @{username} filtered out: "
                f"empty bio, no niche match, no work signals, "
                f"low followers ({followers})"
            )
            return False

        reasons: list[str] = []
        if not bio_empty:
            reasons.append("bio")
        if not no_niche:
            reasons.append("niche match")
        if not no_signals:
            reasons.append("work signals")
        if not low_followers:
            reasons.append(f"{followers} followers")
        log(f"      \u2705 @{username} pre-filter PASSED ({', '.join(reasons)})")
        return True

    except Exception as e:
        log(f"      \u26a0\ufe0f Pre-filter error for @{username}: {e}")
        return True  # keep on error — let qualification decide
#  Scraper agent — visits hashtag pages → opens posts → extracts
#  post owners + commenters.  Adapted from scraper_integration.py but
#  takes hashtags directly from the discovery plan (no config lookup).
# ══════════════════════════════════════════════════════════════════════

MAX_ACCOUNTS_TO_SCRAPE = 120  # hard cap per scrape run


def _scrape_hashtags_from_plan(
    page,
    hashtags: list[str],
    should_stop: Callable,
    log=print,
    visited_posts: set | None = None,
    max_accounts: int = 50,
    target_interest: str = "",
    optional_keywords: list[str] | None = None,
) -> list[str]:
    """
    Navigate to hashtag pages from the discovery plan, open individual
    posts, and extract post owners + commenters.

    Each extracted commenter is **pre-filtered**: a quick profile visit
    checks bio length, niche keywords, work signals, and follower count.
    Only profiles that pass at least one criterion are kept.

    Uses the SAME sync Playwright page as the scrolling loop.

    Returns a list of unique usernames that passed the pre-filter.
    """
    if visited_posts is None:
        visited_posts = set()

    max_accounts = min(max_accounts, MAX_ACCOUNTS_TO_SCRAPE)
    session_hashtags = random.sample(hashtags, min(5, len(hashtags)))

    log(f"🔍 [Scraper] Hashtags to scrape: {session_hashtags}")

    all_usernames: list[str] = []
    seen: set[str] = set()
    collected = 0

    for hashtag in session_hashtags:
        if collected >= max_accounts or should_stop():
            break

        clean_tag = hashtag.lstrip("#")
        log(f"  🏷️ Navigating to #{clean_tag} via search bar...")

        try:
            # Use the search engine to type the hashtag naturally
            if not perform_search(page, f"#{clean_tag}", "hashtag", log):
                log(f"  ⚠️ Could not navigate to #{clean_tag}, skipping...")
                continue

            _human_delay_sync("page_load")

            # Check for login redirect
            if "login" in page.url.lower():
                log("  ⚠️ Redirected to login — skipping this hashtag")
                continue

            # Scroll to load posts on the hashtag page
            for _ in range(random.randint(1, 3)):
                page.keyboard.press("PageDown")
                _human_delay_sync("scroll")

            # Collect post links visible on the hashtag page
            post_links = page.query_selector_all('a[href*="/p/"]')
            post_urls: list[str] = []
            for link in post_links[:MAX_POSTS_PER_HASHTAG * 2]:
                href = link.get_attribute("href")
                if href and "/p/" in href:
                    full_url = (
                        f"https://www.instagram.com{href}"
                        if href.startswith("/")
                        else href
                    )
                    if full_url not in post_urls:
                        post_urls.append(full_url)
                        if len(post_urls) >= MAX_POSTS_PER_HASHTAG:
                            break

            # Filter out already-visited posts
            new_post_urls = [u for u in post_urls if u not in visited_posts]
            skipped = len(post_urls) - len(new_post_urls)
            if skipped > 0:
                log(f"  ⏭️ Skipping {skipped} already-scraped posts")
            log(f"  📝 {len(new_post_urls)} new posts to scrape")

            # Visit each post and extract owner + commenters
            for i, post_url in enumerate(new_post_urls):
                if collected >= max_accounts or should_stop():
                    break

                visited_posts.add(post_url)
                log(f"    📄 Post {i + 1}/{len(new_post_urls)}...")

                try:
                    page.goto(post_url, wait_until="domcontentloaded")
                    try:
                        page.wait_for_selector("article", timeout=10_000)
                    except Exception:
                        pass
                    _human_delay_sync("read_content")

                    # Extract post owner
                    owner = _extract_post_owner(page)
                    if owner and owner not in seen:
                        log(f"      \U0001f464 Owner: @{owner}")

                    # Extract commenters
                    raw_candidates: list[str] = []
                    if owner:
                        raw_candidates.append(owner)
                        log("      \U0001f4ac Scrolling comments...")
                        commenters = _extract_commenters(
                            page, owner, MAX_COMMENTERS_PER_POST, log
                        )
                        if commenters:
                            log(f"      \U0001f4ac Found {len(commenters)} commenters")
                            raw_candidates.extend(commenters)
                        else:
                            log("      \U0001f4ac No commenters found")

                    # ── Pre-filter: visit each candidate's profile ──
                    if raw_candidates and target_interest:
                        log(f"      \U0001f50d Pre-filtering {len(raw_candidates)} candidates...")
                        for candidate in raw_candidates:
                            if candidate in seen or collected >= max_accounts or should_stop():
                                continue
                            passed = _pre_filter_profile(
                                page, candidate, target_interest,
                                optional_keywords, log,
                            )
                            if passed:
                                seen.add(candidate)
                                all_usernames.append(candidate)
                                collected += 1
                            _human_delay_sync("between_posts")
                    elif raw_candidates:
                        # No target_interest — skip pre-filter, keep all
                        for candidate in raw_candidates:
                            if candidate not in seen and collected < max_accounts:
                                seen.add(candidate)
                                all_usernames.append(candidate)
                                collected += 1

                except Exception as e:
                    log(f"      ❌ Post error: {e}")

                _human_delay_sync("between_posts")
                _maybe_take_break_sync(log)

        except Exception as e:
            log(f"  ❌ Hashtag error: {e}")

        # Wait between hashtags
        if hashtag != session_hashtags[-1]:
            log("  ⏳ Waiting before next hashtag...")
            _human_delay_sync("between_hashtags")

    log(f"📊 [Scraper] Total collected: {collected} usernames")
    return all_usernames


# ── Main pipeline ────────────────────────────────────────────────────


def run_smart_lead_pipeline(
    cookies: list[dict],
    target_interest: str,
    optional_keywords: list[str] | None = None,
    max_profiles: int = 50,
    headless: bool = False,
    browser_type: str = "chrome",
    model: str = "gpt-4.1-mini",
    stop_flag=None,
    log_callback=None,
    on_plan_ready: Callable | None = None,
) -> dict:
    """
    Unified lead-generation pipeline: scroll → scrape → qualify → follow.

    Flow
    ----
    1. **Discovery Brain** generates a search plan in a background thread
       while the browser scrolls the feed naturally.
    2. Once the plan arrives the **scraper agent** takes over the page:
       visits hashtag pages from the plan → opens individual posts →
       extracts post owners + commenters → builds a username list.
    3. After scraping completes, enters the **qualification loop**:
       scroll normally on feed → 30 % chance per scroll to visit the
       next profile from the list → search username → scroll profile →
       extract data → qualify with AI → follow if qualified → go back
       to home → keep scrolling → repeat until all profiles done.

    Returns a result dict: leads, all_results, total_scanned,
    total_qualified, profiles_followed, discovery_plan, stats.
    """
    log = create_log_function(log_callback)
    should_stop = create_stop_checker(stop_flag)

    # ── Shared state between threads ──
    plan_holder: dict = {"ready": False, "plan": None, "error": None}
    plan_lock = threading.Lock()

    # ── Phase 1: Discovery Brain (background thread) ──────────────
    def _run_discovery():
        try:
            log("🧠 Phase 1: Generating discovery plan with AI...")
            from agents.discovery_brain import generate_discovery_plan as gen_plan

            plan = gen_plan(
                target_interest=target_interest,
                optional_keywords=optional_keywords,
                max_profiles=max_profiles,
                model=model,
            )
            with plan_lock:
                plan_holder["plan"] = plan
                plan_holder["ready"] = True

            hashtags = plan.get("hashtags", [])
            queries = plan.get("search_queries", [])
            seeds = plan.get("seed_accounts", [])
            log(
                f"✅ Discovery plan ready: "
                f"{len(hashtags)} hashtags, {len(queries)} queries, {len(seeds)} seeds"
            )

            # Surface the plan to the caller (e.g. update task result)
            if on_plan_ready:
                on_plan_ready(plan)

        except Exception as e:
            with plan_lock:
                plan_holder["error"] = str(e)
                plan_holder["ready"] = True
            log(f"❌ Discovery plan error: {e}")

    discovery_thread = threading.Thread(target=_run_discovery, daemon=True)
    discovery_thread.start()

    # ── Prepare Qualification Brain ──
    log("Loading Qualification Brain...")
    from agents.qualification_brain import make_inline_qualifier

    qualify_fn = make_inline_qualifier(model=model)

    # ── State ──
    collected_usernames: list[str] = []
    visited_posts: set[str] = set()
    qualified_leads: list[dict] = []
    stats = {
        "scrolls": 0,
        "likes": 0,
        "scraper_runs": 0,
        "profiles_visited": 0,
        "profiles_followed": 0,
        "total_scanned": 0,
        "total_qualified": 0,
    }
    plan_received = False
    scraping_done = False

    # ── Launch browser ──
    with sync_playwright() as p:
        browser, context, page = launch_instagram_browser(
            p, cookies, headless, log, browser_type=browser_type,
        )

        # ════════════════════════════════════════════════════════════
        #  Phase 2 — Scroll normally while waiting for the discovery
        #  plan, then run the scraper agent to collect usernames.
        # ════════════════════════════════════════════════════════════
        log(f"\n🔄 Phase 2: Scrolling & waiting for discovery plan...")

        while not should_stop() and not scraping_done:
            # ── Normal feed scroll ──
            stats["scrolls"] += 1
            status = "🧠 Waiting for plan..." if not plan_received else "🔍 Scraping..."
            log(
                f"📜 Scroll #{stats['scrolls']} | "
                f"❤️ {stats['likes']} | "
                f"📋 {len(collected_usernames)} collected | {status}"
            )

            do_single_scroll(page, log)
            if try_random_like(page, log=log):
                stats["likes"] += 1

            # ── Check if discovery plan arrived ──
            if not plan_received:
                with plan_lock:
                    if plan_holder["ready"]:
                        if plan_holder["error"]:
                            log(f"❌ Discovery failed: {plan_holder['error']}. Stopping.")
                            break
                        plan_received = True
                        log("📋 Discovery plan received! Starting scraper agent...")

            # ── Scraper: runs once the plan is ready ──
            if plan_received and not scraping_done:
                plan = plan_holder["plan"]
                hashtags = plan.get("hashtags", [])

                if not hashtags:
                    log("⚠️ No hashtags in discovery plan. Skipping scraping phase.")
                    scraping_done = True
                    continue

                stats["scraper_runs"] += 1
                log(f"\n🔬 SCRAPER AGENT STARTING (run #{stats['scraper_runs']})")
                log(f"📌 {len(visited_posts)} posts already scraped")

                # ── Core scraping: visit hashtag pages → open posts →
                #    extract owners + commenters (same page) ──
                new_usernames = _scrape_hashtags_from_plan(
                    page=page,
                    hashtags=hashtags,
                    should_stop=should_stop,
                    log=log,
                    visited_posts=visited_posts,
                    max_accounts=max_profiles,
                    target_interest=target_interest,
                    optional_keywords=optional_keywords,
                )

                # De-duplicate and store
                existing_set = set(collected_usernames)
                for uname in new_usernames:
                    if uname not in existing_set:
                        collected_usernames.append(uname)
                        existing_set.add(uname)

                log(
                    f"📊 Scraper collected {len(new_usernames)} usernames "
                    f"(total unique: {len(collected_usernames)})"
                )

                # Navigate back to feed after scraping
                go_back_to_feed(page, log)
                scraping_done = True

                # A few natural scrolls to look human before qualification
                log("📜 Resuming natural scrolling before qualification phase...")
                for _ in range(random.randint(2, 4)):
                    if should_stop():
                        break
                    do_single_scroll(page, log)
                    if try_random_like(page, log=log):
                        stats["likes"] += 1
                    stats["scrolls"] += 1

        # ── Early exit if stopped or nothing collected ──
        if should_stop() or not collected_usernames:
            log("No accounts collected or stopped. Closing browser...")
            context.close()
            browser.close()
            return _build_result(
                plan_holder.get("plan") or {}, qualified_leads, stats
            )

        # ════════════════════════════════════════════════════════════
        #  Phase 3 — Scroll normally + visit profiles on 30 % chance
        #  Keep going until max_profiles QUALIFIED leads are found
        #  or 100 profiles have been visited (safety cap).
        # ════════════════════════════════════════════════════════════
        SAFETY_CAP = 100  # max profiles to visit before giving up
        MAX_RESCRAPE_ROUNDS = 2  # extra scrape rounds if quota not met
        rescrape_round = 0
        visit_index = 0
        log(
            f"\n🎯 Phase 3: Qualification loop — need {max_profiles} qualified leads "
            f"(30% chance per scroll, safety cap={SAFETY_CAP})"
        )

        while (
            stats["total_qualified"] < max_profiles
            and stats["profiles_visited"] < SAFETY_CAP
            and not should_stop()
        ):
            # ── If we've exhausted collected usernames, try re-scraping ──
            if visit_index >= len(collected_usernames):
                if rescrape_round < MAX_RESCRAPE_ROUNDS and plan_holder.get("plan"):
                    rescrape_round += 1
                    plan = plan_holder["plan"]
                    hashtags = plan.get("hashtags", [])
                    if hashtags:
                        log(
                            f"\n🔄 Re-scrape round {rescrape_round}/{MAX_RESCRAPE_ROUNDS} "
                            f"— need {max_profiles - stats['total_qualified']} more qualified leads"
                        )
                        go_back_to_feed(page, log)
                        new_usernames = _scrape_hashtags_from_plan(
                            page=page,
                            hashtags=hashtags,
                            should_stop=should_stop,
                            log=log,
                            visited_posts=visited_posts,
                            max_accounts=max_profiles * 3,
                            target_interest=target_interest,
                            optional_keywords=optional_keywords,
                        )
                        existing_set = set(collected_usernames)
                        for uname in new_usernames:
                            if uname not in existing_set:
                                collected_usernames.append(uname)
                                existing_set.add(uname)
                        go_back_to_feed(page, log)
                        log(f"📊 Re-scrape added {len(new_usernames)} usernames (total: {len(collected_usernames)})")
                        if visit_index >= len(collected_usernames):
                            log("⚠️ No new usernames found. Stopping.")
                            break
                        continue
                    else:
                        log("⚠️ No hashtags available for re-scrape. Stopping.")
                        break
                else:
                    log(
                        f"⚠️ All {len(collected_usernames)} usernames exhausted "
                        f"after {rescrape_round} re-scrape rounds. Stopping."
                    )
                    break

            # ── Normal feed scroll ──
            stats["scrolls"] += 1
            remaining_quota = max_profiles - stats["total_qualified"]
            log(
                f"📜 Scroll #{stats['scrolls']} | "
                f"❤️ {stats['likes']} | "
                f"👤 {stats['profiles_visited']}/{SAFETY_CAP} visited | "
                f"✅ {stats['total_qualified']}/{max_profiles} qualified | "
                f"🎯 {remaining_quota} more needed"
            )

            do_single_scroll(page, log)
            if try_random_like(page, log=log):
                stats["likes"] += 1

            # ── 30 % chance to visit the next profile ──
            if random.random() < 0.30:
                username = collected_usernames[visit_index]
                visit_index += 1

                log(f"\n{'=' * 40}")
                log(
                    f"👤 [{stats['profiles_visited'] + 1}/{SAFETY_CAP}] Visiting @{username}"
                )
                log(f"{'=' * 40}")

                try:
                    # Search for the profile
                    if not perform_search(page, username, "username", log):
                        log(f"⚠️ Could not find @{username}, skipping...")
                        go_back_to_feed(page, log)
                        continue

                    time.sleep(random.uniform(2.5, 4.0))
                    stats["profiles_visited"] += 1
                    stats["total_scanned"] += 1

                    # Scroll on the profile page (human-like)
                    num_scrolls = random.randint(3, 6)
                    log(f"📜 Scrolling {num_scrolls} times on profile...")
                    scroll_on_page(page, num_scrolls, should_stop, log)

                    # Force a full page load to refresh meta tags
                    # (Instagram SPA doesn't update og:* tags on
                    #  client-side navigation, causing stale data)
                    log(f"🔄 Reloading @{username} profile for fresh data...")
                    page.goto(
                        f"https://www.instagram.com/{username}/",
                        wait_until="domcontentloaded",
                    )
                    try:
                        page.wait_for_selector(
                            'meta[property="og:description"]',
                            timeout=8_000,
                        )
                    except Exception:
                        pass
                    _human_delay_sync("read_content")

                    # Extract profile data
                    profile_data = _extract_sync_profile_data(
                        page, username, log
                    )
                    profile_data["discovery_source"] = "smart_pipeline"

                    # Qualify with AI
                    log(f"🧠 Qualifying @{username}...")
                    scored = qualify_fn(profile_data)

                    if scored and scored.get("is_target"):
                        stats["total_qualified"] += 1
                        qualified_leads.append(scored)

                        log(
                            f"✅ @{username} QUALIFIED! "
                            f"(score={scored.get('total_score', 0)}, "
                            f"confidence={scored.get('confidence', '?')}) "
                            f"[{stats['total_qualified']}/{max_profiles}]"
                        )

                        # Follow the account
                        followed = scroll_to_top_and_follow(
                            page, username, log
                        )
                        if followed:
                            stats["profiles_followed"] += 1
                            log(f"➕ Followed @{username}!")

                        # Check if we've hit our quota
                        if stats["total_qualified"] >= max_profiles:
                            log(f"🎉 Quota reached! {max_profiles} qualified leads found.")
                            break
                    else:
                        score = (
                            scored.get("total_score", 0) if scored else 0
                        )
                        log(f"✗ @{username} not qualified (score={score})")

                    # Return to home via navigation bar
                    go_back_to_feed(page, log)

                    # Natural delay before resuming scrolling
                    time.sleep(random.uniform(3, 8))

                except Exception as e:
                    log(f"❌ Error with @{username}: {e}")
                    try:
                        go_back_to_feed(page, log)
                    except Exception:
                        pass

        # ── Summary ──
        log(f"\n{'=' * 50}")
        log("🏁 SMART PIPELINE COMPLETE")
        log(f"{'=' * 50}")
        log(f"📜 Total scrolls: {stats['scrolls']}")
        log(f"❤️ Total likes: {stats['likes']}")
        log(f"🔬 Scraper runs: {stats['scraper_runs']}")
        log(f"👤 Profiles visited: {stats['profiles_visited']}")
        log(f"✅ Qualified leads: {stats['total_qualified']}")
        log(f"➕ Profiles followed: {stats['profiles_followed']}")
        log(f"{'=' * 50}")

        log("Closing browser...")
        context.close()
        browser.close()

    return _build_result(plan_holder.get("plan") or {}, qualified_leads, stats)


# ── Result builder ───────────────────────────────────────────────────


def _build_result(plan: dict, leads: list[dict], stats: dict) -> dict:
    """Build the final result dict matching the LeadGenResult shape."""
    leads_sorted = sorted(leads, key=lambda x: -(x.get("total_score") or 0))
    return {
        "leads": leads_sorted,
        "all_results": leads_sorted,
        "total_scanned": stats.get("total_scanned", 0),
        "total_qualified": stats.get("total_qualified", 0),
        "profiles_followed": stats.get("profiles_followed", 0),
        "discovery_plan": plan or {},
        "stats": stats,
    }
