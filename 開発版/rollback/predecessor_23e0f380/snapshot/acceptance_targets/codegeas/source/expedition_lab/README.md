# Seamless Expedition Prototype — Hospital District

This is an isolated, non-canonical prototype. It does not replace Day1, the Sandbox Foundation, Combat Lab A-E, Save data, or stable runtime assets.

## Human playtest

Run the scene directly:

```bash
godot --path game res://expedition_lab/ExpeditionPrototypeLab.tscn
```

- Left click a blue/green friendly to select it.
- Right click ground or a visible target, then choose a context command.
- Pause/1x/4x/8x buttons (or Space/1/4/8) control the shared simulation clock.
- Issued movement shows and follows a route around the central rubble blocker instead of crossing it.
- Once an enemy has detected the squad and the player resumes time, that enemy can pursue and counterattack on the same map.
- Role buttons assign Follow, Scout, Guard, Medic, Repair, or HoldFire to the selected unit.
- Yellow circles are loot, cyan squares are information, green markers are rescue targets.
- Enemy truth is never drawn directly. Signal/estimated/confirmed/lost-contact markers come only from Player Knowledge.
- Start retreat, physically move the hero to the southwest primary extraction (or use the backup route as conditions demand), then press the extraction check.
- Carried casualties and escorted civilians only count as returned/rescued when they physically reach extraction.
- A hostile KMF can be rendered combat-ineffective by destroying its weapon and both legs while leaving the cockpit/pilot intact.

Suggested first loop: scout north, inspect the radio wreck or hospital terminal, recover the medical cache, confirm or avoid a patrol, rescue the civilian, then retreat. Damage feedback in the selected-unit panel shows why leg, sensor, or weapon damage changes available choices.

Metrics are held in `ExpeditionState.metrics`: orders, manual/automatic pauses by reason, confirmed contacts, combat, kills/incapacitations, damage, rescues, loot acquired/abandoned, KMF abandonment, retreat, and real/simulation time.
