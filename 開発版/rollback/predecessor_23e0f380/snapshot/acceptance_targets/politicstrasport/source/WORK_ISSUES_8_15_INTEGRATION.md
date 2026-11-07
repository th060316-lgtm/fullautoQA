# Work / Grok Logic Integration — Issues #4–#16

## Status

This branch is the integrated Logic Prototype candidate for Issues #4–#16.
Grok Phase A (#4–#7 and economic diagnostics backend) is already integrated with
Work Phase B/C (#8–#15). This document describes the current combined contract,
not the earlier pre-Grok stub state.

## Daily order

1. `WorldDynamicsSystem.process_pre_transport()` updates politics, diplomacy,
   front position, occupation/blockade and route disruption.
2. `EconomySystem.process_day()` prepares the integrated EconomicCore and remains
   the sole owner of exactly one `TransportSystem.process_transport()` call.
3. Existing `PoliticalSystem` and `WarSystem` update legacy-compatible state.
4. `WorldDynamicsSystem.process_post_transport()` applies war damage,
   reconstruction, nation/company lifecycle, corporate transfers, player
   interventions and diagnostics.
5. AI reevaluates routes after the world/economy consequences are known.

## Integrated Phase A boundary

`WorldDynamicsSystem.set_economy_delegate(world.economic_core)` connects the
Work side to the integrated EconomicCore through `EconomyBridge`.

Supported delegate methods:
- `get_demand_multiplier(settlement_id, cargo_key)`
- `notify_regional_shock(settlement_id, category, magnitude)`
- `choose_facility_operator(settlement_id, facility_type)`
- `register_player_built_facility(facility)`
- `diagnostic_snapshot()`

Additional integration now used by war/world dynamics:
- EconomicCore facility war damage / repair
- industrial market expansion from military and reconstruction demand
- contextual military-industrial facilities

## Issue coverage

- #4: data-driven cargo registry, independent facilities and industry companies.
- #5: market saturation, diminishing unit value, non-zero local recirculation floor.
- #6: regional economy and city growth/decline loop.
- #7: transport-profit reinvestment, industry expansion/contraction and splits.
- #8: economic systems plus political logistics profiles, diplomacy/policy demand effects.
- #9: moving front, occupation, blockade, disruption and supply-base relocation.
- #10: city/facility damage, refugees, military industry and long reconstruction.
- #11: rebellion, nation split/integration plus rare upset/state-collapse outcomes.
- #12: dynamic entry/exit/split/merge, related-industry entry, AI strategies and
  functional cooperative demand pooling.
- #13: equity/subsidiaries, hostile acquisition, related construction/vehicle/
  maintenance businesses, dividends, outsourcing and high-level subsidiary directives.
- #14: city support, promotion, regional investment, company investment and
  player-built industry with automatic non-player operation.
- #15: route-profit reasons, economic/world event diagnostics and map overlays.
- #16: the combined transport -> economy -> world -> route-value feedback loop.

## Accounting invariants

- Player cash exists in `WorldState.money`; `TransportCompany.money` is a synchronized mirror.
- Every direct payment uses `WorldState.pay_company()` once.
- Every transport/dividend credit uses `WorldState.add_company_revenue()` once.
- Dividend transfer debits the child once and credits the parent once.
- Player-built industry facilities always remain non-player-owned and receive a
  local industry operator after completion.
- Owning a related construction/vehicle/maintenance company changes service
  economics only; it never unlocks vehicle R&D.

## Cooperation contract

Companies in one cooperation group are treated as one demand-acquisition actor.
Demand is first allocated by route score, then any unserved demand is pooled
inside that cooperation group and moved onto partner routes with spare capacity.
Revenue and accounting remain attached to the route's actual company.

## War/economy contract

War can reduce a facility's effective production through `war_damage`.
Military and reconstruction pressure expands the INDUSTRIAL cargo market, used
as the Logic Prototype proxy for military manufacturing / construction materials /
machinery. Reconstruction gradually repairs both city and facility damage.

## Scope exclusions

No vehicle R&D, detailed stock exchange, employee management, factory-internal
management, political unit control or tactical combat is introduced.

## Acceptance

The branch workflow must pass on the final HEAD:
- Linux complete regression
- Windows complete regression
- WorkCompletionAcceptanceTest
- EconomicCoreIntegrationTest
- WorldDynamicsAcceptanceTest (365-day)
- existing FullIntegration / UIInteraction / HOLD / Destructive / Font
- existing 300-day LongRunProfile
- Windows standard seven scenarios
- 1280x720 visual smoke

`main/安定版` is not modified by this branch.
