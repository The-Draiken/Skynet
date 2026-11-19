# Skynet - Smart Tactical AI for Combat Extender

## Core Idea
You use Combat Extender configs that give enemies **lots** of spells (from your "Spells I Use", Cahoot/Abs Lab emulation, roguetest, etc.).

The problem: Vanilla AI + big lists = freeze, skip turns, or cast garbage (Enhanced Leap when they should smite/fireball).

**Skynet's job**: Make the AI *choose intelligently* from whatever big list CE gave them.

It does **not** give enemies free power or auto-counters by default. All the tactical analysis happens so the enemy picks the *right* spell for the situation — like a human would.

## What it analyzes right now (and will use more of your data for)
- Player recent actions (via CombatHistory from casts)
- Player loadout: classes, passives, statuses, equipped spells (pulled from entity data + your "Spells I Use" + ModsttoConsider folders)
- Battlefield: positions, height differences, clustering
- Enemy's own kit: what passives/spells they actually have from your CE config (e.g. LAB_Progression_Paladin_Conquest, auras, smites)
- Synergies (e.g. if enemy has Conquest aura, score fear/control higher)
- Avoids useless stuff (heavily penalizes self-buffs like Leap unless height disadvantage makes it good)
- Recent history (doesn't repeat the same control spell 3 times in a row)

## How the smart choice works
On an enemy's turn (if they have a large spell list from CE, >8 spells):
1. Builds rich context.
2. Scores every available spell using the tactical rules above.
3. Picks the highest scoring one and forces the cast on a good target (with logging so you see why).

Example scoring logic:
- Damage spells get big points if player is clustered or has concentration to break.
- Control gets points but is de-prioritized if you've already used a lot recently.
- Self-mobility (Leap/Jump) gets -12 unless the player literally has high ground on them.
- Paladin with Conquest aura + fear spell = high synergy bonus.
- Uses your roguetest data for anti-stealth, Cahoot lists for class-appropriate choices, etc.

## MCM
- `EnableReactiveCounters` (default false): The old "give free anti-control/height statuses" behavior. Leave off for immersion.
- `EnableDebugLogging`: Shows exactly what Skynet is thinking and what it forces.

## Integration with your stuff
- Works **on top of** your existing Combat Extender configs (the 7-party ones, shadow-druid, full Cahoot emulation, etc.).
- Pulls spell/passive knowledge from "Spells I Use/" and "ModsttoConsider/" (roguetest especially, plus the DTO codex you linked).
- Respects Cahoot/Abs Lab profiles you already use for class emulation.
- Compatible with SmarterAI, CombatExtenderAI, UTAC, Total AI Control, etc. (it layers smart selection on top of their archetypes).

## Obstacle & Environment Awareness (new)
Skynet now factors in obstacles:

- **Globe of Invulnerability** (your custom mod): Detects the custom dome objects (using the mod's templates and blocker stats). If a Globe is protecting players, destruction spells get high priority. Prefers non-physical damage (the Globe is immune to B/P/S, resistant to most else). Will target the Globe object directly when it's the smartest move.

- **Wall of Stone, doors, gates**: Detects objects with "wall"/"stone"/"door"/"gate" in name. Scores:
  - Smash through: High-damage spells (force, fire, acid, lightning from your "Spells I Use") if enemy has strength or good damage.
  - Bypass: Jump/Fly/Teleport spells if the enemy has the capability (checked from their current spell list + maneuverability).
  - Go around: Lower priority if other options are better.

- Enemy capabilities considered: Strength (for breaking), jump/fly spells or passives (for leaping over), movement speed.
- Example: Weak enemy vs Wall of Stone → prefers teleport/jump over wasting actions smashing. Strong brute with high damage → smashes.

This builds on base game behavior (worgs attacking gates) but makes it smart and consistent with your CE spell lists + custom Globe.

The Globe mod's "impenetrable dome" will now be actively targeted by enemies when it blocks access to high-value targets.

## Current limitations & future
- Force-casting is direct (to guarantee the smart choice). Can be made softer later (e.g. just boost archetype).
- More data from your folders will be parsed for better classification over time.
- Full LOS/pathfinding for complex walls coming (current uses name + proximity + height).
- Can be extended to also help your party members via UTAC-style logic.

Load Skynet + your CE config + the AI mods you like. Watch the console for "[Skynet]" recommendations and forced casts.

If you want the force-casting turned into "just recommend + apply a smart archetype" instead of forcing, or want specific rules for Anders/Cyrel, or want it to also handle the "too many spells causing skip" by pruning bad ones at start, tell me.

This should make fights feel like playing against a human who sees your tactics and picks the right tool from the toolbox you gave them.