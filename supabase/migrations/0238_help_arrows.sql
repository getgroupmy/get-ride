-- ============================================================================
-- 0238 — No "→" in the help articles
--
-- The help articles seeded by 0130 (and updated by 0132 and 0194) write menu
-- paths as "Settings → Change sign-in PIN". Some Android fonts have no glyph
-- for U+2192 and show an empty box. The app's own copy now writes menu paths
-- and chains with ">" ("Settings > Bluetooth") and routes or changes with
-- "to" ("KLCC to KL Sentral"). Every arrow in the seeded articles is a menu
-- path, so each "→" becomes ">", keeping the spacing around it: " → " reads
-- " > ", and an arrow with no spaces ("A→B") reads "A>B". The same goes for
-- an article an admin wrote or edited, since the edits live in these rows.
--
-- Columns: help_articles.title, question_variants (text[]), answer, keywords
-- (text[]), category and action_label (action_route's check already refuses
-- anything but a path), and help_questions.question (what people asked,
-- which the admin's "Create article from this" copies into a new article).
--
-- Only rows that hold an arrow are updated, so running this again changes
-- nothing. help_articles' BEFORE UPDATE trigger (help_articles_search_doc,
-- 0130) rebuilds search_doc, so the full-text index follows the new text,
-- and stamps updated_at = now() on the rows that changed. help_questions has
-- no triggers or derived columns. Lengths are unchanged (one character for
-- one), so the length checks still hold.
-- ============================================================================

update public.help_articles a
   set title = replace(a.title, '→', '>'),
       question_variants = array(
         select replace(v, '→', '>') from unnest(a.question_variants) with ordinality as u(v, n) order by n),
       answer = replace(a.answer, '→', '>'),
       keywords = array(
         select replace(k, '→', '>') from unnest(a.keywords) with ordinality as u(k, n) order by n),
       category = replace(a.category, '→', '>'),
       action_label = replace(a.action_label, '→', '>')
 where strpos(a.title, '→') > 0
    or strpos(array_to_string(a.question_variants, ' '), '→') > 0
    or strpos(a.answer, '→') > 0
    or strpos(array_to_string(a.keywords, ' '), '→') > 0
    or strpos(a.category, '→') > 0
    or strpos(coalesce(a.action_label, ''), '→') > 0;

update public.help_questions
   set question = replace(question, '→', '>')
 where strpos(question, '→') > 0;
