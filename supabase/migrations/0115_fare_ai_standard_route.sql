-- 0115: Fare AI response log keeps the standard route it was compared with.
--
-- Admin → Fare AI → Fare trend arrows: ai-route-proxy fetches the standard
-- route (OSRM, empty roads) alongside the AI and compares the two drive
-- times to decide the up / down arrows before the recommended fare. Both
-- figures are kept on each answer so the Fare AI page can show how far the
-- AI usually sits from standard, and the thresholds can be set from real
-- trips. NULL when the standard route could not be had.

alter table public.fare_ai_responses add column if not exists standard_duration_min numeric;
alter table public.fare_ai_responses add column if not exists standard_distance_km numeric;
