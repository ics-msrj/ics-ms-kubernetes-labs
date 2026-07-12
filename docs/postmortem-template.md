# Postmortem: {{ incident title }}

**Date**: {{ YYYY-MM-DD }}
**Author**: {{ you }}
**Severity**: {{ SEV1 (full outage) / SEV2 (degraded, user-facing) / SEV3 (degraded, internal only) }}
**Status**: {{ draft / reviewed / final }}

This is a **blameless** postmortem. The goal is to understand what the system did and why, not to find who to blame — if a step reads like it's assigning fault to a person, rewrite it around the system/process instead.

## Summary

*Two or three sentences. What broke, for how long, who/what was affected. Someone who reads only this section should understand the whole incident.*

## Impact

- **User-facing?** {{ yes/no — which flows }}
- **Duration**: {{ start time }} → {{ end time }} ({{ total }})
- **Scope**: {{ which services/namespaces/nodes }}

## Timeline

*All times in the same timezone, ideally UTC. Pull exact timestamps from Grafana/Loki/`kubectl get events` rather than reconstructing from memory.*

| Time | Event |
|---|---|
| {{ HH:MM }} | {{ First symptom — what did you actually SEE, in which tool? }} |
| {{ HH:MM }} | {{ Detection — what alert fired, or what made you look? }} |
| {{ HH:MM }} | {{ Diagnosis steps — what did you check, what did you rule out? }} |
| {{ HH:MM }} | {{ Root cause identified }} |
| {{ HH:MM }} | {{ Mitigation applied }} |
| {{ HH:MM }} | {{ Confirmed recovered }} |

## Detection

- **How was this detected?** {{ Prometheus alert / Grafana dashboard / manual observation / user report }}
- **Time to detect** (incident start → first human awareness): {{ duration }}
- **Could it have been detected sooner?** {{ honest answer — a missing alert rule, a dashboard nobody was watching, etc. }}

## Root Cause

*Not just "what broke" — why did it break, one level deeper than the symptom. If two things went wrong at once (a real GameDay scenario often does this), name both — resist the urge to write up only the first one you found.*

## Diagnosis Process

*What did you actually check, in what order, and what did each step rule in or out? This section is as valuable as the root cause itself — it's the reusable part for the next incident.*

1. {{ Checked X, saw Y, which told me Z }}
2. {{ ... }}

## Resolution

*What action actually fixed it. Distinguish mitigation (stopped the bleeding) from full resolution (root cause actually addressed) if they were different steps.*

## What Went Well

*Real ones only — "we had a dashboard for this" or "the alert fired within 30s" are legitimate. Skip this section's content rather than padding it with vague positivity.*

## What Went Poorly

*Also real ones. "We didn't notice for 8 minutes because nobody was watching that dashboard" is exactly the kind of finding this section exists for.*

## Action Items

| Action | Owner | Priority |
|---|---|---|
| {{ specific, checkable action — not "improve monitoring" }} | {{ who }} | {{ P0/P1/P2 }} |

*Every action item should be something you could literally open as a ticket. "Add a PrometheusRule alerting on currencyservice p99 latency > 2s" is an action item. "Be more careful" is not.*
