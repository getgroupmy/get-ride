-- 0114: Fare AI response log keeps the optional answers.
--
-- Admin → Fare AI → Request & format can now also ask the AI for the fare
-- range (current_duration_is_baseline / _is_low / _is_heavy) and traffic
-- (traffic_congestion and the congested stretches). ai-route-proxy stores
-- whatever of those came back, after checking it, in this one column so the
-- response log can show them; NULL when none were asked for or usable.

alter table public.fare_ai_responses add column if not exists extra jsonb;
