# Skynet – Adaptive Enemy AI

**A Baldur's Gate 3 Script Extender mod that makes enemies fight like thinking opponents.**


· Current version: **7.0.0.0**

Skynet takes over enemy turns and plays them like a thinking opponent. Every turn it reads the fight: who is where, who is hurt, who is hidden, who keeps hitting hardest. Then it picks the best action from what that enemy actually has. It doesn't give enemies new spells or free power (unless you turn on the optional Enemy Buffs). It makes them use their own kit well, and it learns how you fight.

It was built for heavily modded games, where Combat Extender and similar mods give enemies huge spell lists that make the base game AI freeze, skip turns or cast nonsense.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [How a Skynet turn works](#how-a-skynet-turn-works)
- [Smarter decisions](#smarter-decisions)
- [Hidden and invisible characters](#hidden-and-invisible-characters)
- [Fair movement](#fair-movement)
- [It learns how you fight](#it-learns-how-you-fight)
- [Optional systems](#optional-systems-all-off-by-default)
- [Built-in Auto Save](#built-in-auto-save-its-own-mcm-tab)
- [Mod compatibility details](#mod-compatibility-details)
- [Settings](#settings-mcm--skynet)
- [Good to know](#good-to-know)
- [Reporting a problem](#reporting-a-problem)
- [Repository layout](#repository-layout)
- [Credits](#credits)

---

## Requirements

- **BG3 Script Extender**
- **Mod Configuration Menu (MCM)** to change settings. Without it, Skynet runs on its defaults.

Optional, and recognised when installed: Combat Extender, Grit and Glory, Additional Spell Interactions, Rogue Test (Combat Mastery), the 2e Spells mod, apcs_RestSystem, Gray's Bondage, DSleep, True Rage Unlimited, Spoils of War.

---

## How a Skynet turn works

1. **Checks who should play the turn.** Your party, your summons, your familiars and modded companions you control are never touched; NPC allies fighting beside you (for example Spoils of War pets) are played by Skynet too. Surprised, downed, charmed, taunted, frightened, slowed, stunned, asleep and similar enemies are left to the base game, which handles those rules. If a taunt or fear wears off just as the enemy's turn starts, Skynet takes that turn back.
2. **Reads the battlefield.** Positions, line of sight, height, hazards on the ground (fire, acid, webs, grease and more), concentration, statuses, and who is genuinely hidden or invisible.
3. **Prepares.** Uses one self-buff it doesn't already have, a weapon coating, a potion, or a heal when hurt. It cures poison, blindness and petrification with antidotes and remedies, and backs off first if drinking costs its whole action.
4. **Moves, then acts.** Walks for free first, uses Dash, Jump, Misty Step or Fly only when needed, then casts or attacks with whatever scores best right now.
5. **Uses everything it has.** Skynet tracks the enemy's real actions and bonus actions. A mid-turn extra action, such as from Enrage, gets used.
6. **Hands back cleanly.** If Skynet has no real way to reach anyone, it gives the whole turn to the base game AI instead of doing something silly. When Skynet's own queued actions are done, it lets the base game AI finish what is left of the turn, or ends the turn itself.

---

## Smarter decisions

- **Spell choice by situation.** Every option is scored on damage, area, crowd control, the target's resistances and vulnerabilities, concentration, and the enemy's own passives. Damage is favoured against clustered parties, control against a concentrating caster, and so on.
- **Weapon attacks and real spells come first.** Big modded spell books start with filler actions like Throw, Help, Distract and Shove. Skynet always looks at the weapon attack and the enemy's own spells first.
- **No wasted actions:**
  - It won't break its own concentration with a second concentration spell.
  - It won't recast a buff or control spell on a target that already has it.
  - It won't recast Rage while raging, and it never uses End Rage.
  - Help, Distract and Throw are never treated as attacks, and Help is never cast on an enemy.
  - Dip is only used on a surface or burning object, never on a creature, and once per fight.
  - Self-only spells are never aimed at anyone else.
- **Limited abilities are respected.** Once-per-fight and once-per-rest abilities, such as Action Surge, are used once. Skynet remembers this through saves and reloads, and short or long rests refresh them.
- **Big abilities in the right moment only:**
  - Dig Deeper only when Second Wind is gone and the enemy is badly hurt.
  - Hyper Focus only when hurt and its attacks keep missing.
  - Heroic Action Surge only when the enemy's side is losing.
- **Opportunity attacks.** Skynet weighs the risk before leaving someone's reach, and ranged enemies kite: they disable, push or finish off an adjacent threat before backing away.
- **Hazards.** Enemies avoid walking through dangerous surfaces, and get out of one they are standing in.
- **Obstacles.** Enemies recognise walls, doors and gates, and the Globe of Invulnerability, and choose whether to break through or go around.

---

## Hidden and invisible characters

If a party member is genuinely hidden, sneaking or invisible, Skynet will not target them, walk toward them or "sense" them through walls. That turn goes to the base game's own search behaviour. Invoke Duplicity is fully understood: enemies can be fooled by the duplicate and target it.

---

## Fair movement

Every Skynet walk follows the game's real walking route. An enemy only goes as far as its movement for the turn allows, plus one more for each Dash. If there is no way to walk there, it doesn't move. If the game ever tries to snap an enemy onto its destination through a blocked walk, Skynet puts it back where it was.

---

## It learns how you fight

- **Your party's style.** Across fights Skynet keeps a profile of your party: melee or ranged, favourite elements, how much you control, heal or summon. If your party kites, enemies get better at closing in and pinning you down. If it charges in, they get better at keeping range and using area spells.
- **Smart enemies remember you (Intelligence).** Enemies with high Intelligence remember each party member across your whole playthrough. They know who usually deals the damage, and they weigh Armor Class and HP when picking a target.
- **Perceptive enemies notice you (Wisdom).** Enemies with high Wisdom notice who is hurting them most in this fight, after a few rounds.
- **Cunning enemies do both.** Enemies with both open with what they know about you, then adapt if you change tactics mid-fight.
- **Low Intelligence and Wisdom.** Beasts, oozes and mindless creatures don't learn; they fight by distance and opportunity.

---

## Optional systems (all off by default)

- **Enemy Downed System.** Living, humanoid enemies make death saving throws at 0 HP instead of dying at once. Their allies try to heal them back up, and a big enough hit kills outright. Undead, constructs and other non-living creatures die normally.
- **Party Downed Rules.** Downed Condition 5E's rules for your party, run through Script Extender. Disable Downed Condition 5E if you use this.
  - A hit bigger than current + max HP kills outright.
  - Unused actions come back when you get up.
  - You stand up Prone.
- **Enemy Buffs.** Extra max HP (0–100%), extra Actions (0–3) and extra Bonus Actions (0–3) for enemies in your fights. These can scale with party size, and are removed when the fight ends. It replaces Tactician Enhanced, so disable that mod if you use this.
- **Enemy Wildshape / Polymorph.** Off by default: enemies won't shape-change, and the form spells are removed from them when a fight starts, so the base game AI can't use them either. On: an enemy may transform once per fight, and never while already transformed.
- **Reactive Counters.** The old "enemies gain resistances against your repeated tactics" statuses. Off for immersion; smart choices are meant to be enough.

---

## Built-in Auto Save (its own MCM tab)

A full auto-save system written for Skynet, with crash-safe rules. Use it instead of separate auto-save mods, not together with them. The game's own autosave option must be on.

**When to save:** each option can be turned on or off on its own.

| Option | Default |
|---|---|
| When a fight ends | On |
| When a fight begins (on the first party turn, once it has settled) | Off |
| On a timer (minutes, or seconds with a 30-second minimum; any save resets it) | On, every 10 minutes |
| After a dialogue | Off |
| After trading | Off |
| After a short rest | On |
| After a long rest | Off |

**Safety:**

- Never saves while combat is starting or ending. You set how long things must stay calm before it saves (1–15 seconds, default 3).
- Never saves while an enemy is downed and making death saves. A save at that moment can crash on load if the enemy stands up and a fight starts. The fight-end save waits until it dies or gets up.
- Saves that come due during combat, dialogue or trading wait until it's over.
- With "Warn about unsafe moments", which works even when auto save is off, you get a message when an enemy is downed outside combat, and after any save you made at such a moment.

---

## Mod compatibility details

- **Combat Extender.** Skynet chooses sensibly from huge spell lists. It also adds the missing level 7–9 bonus spell slots for CX_Spells_L7/L8/L9: 3, 2 and 1 slots.
- **Grit and Glory.** Enemies target and finish off injured, exhausted or maddened characters.
- **Additional Spell Interactions.** Enemies use susceptibility and exposure and set up elemental combos.
- **Rogue Test (Combat Mastery).** Its Death's Door status is no longer applied to enemies; Skynet's own downed system handles them.
- **apcs_RestSystem:**
  - Small enemies with rope try to tie up downed or grappled party members, and grapple first when it helps.
  - Enemies may equip gear they stripped from a tied-up character.
  - Unloaded crossbows cost an extra bonus action for enemies, and Skynet plans around it.
- **2e Spells.** A humanoid enemy can trade two bonus actions for an action when it needs one (for example to equip looted gear).
- **Gray's Bondage.** Without apcs_RestSystem, small enemies carrying its rope sometimes use it on your party.
- **DSleep.** Enemies put to sleep stay asleep instead of getting up to chase the caster.
- **True Rage Unlimited.** Raging enemies don't recast Rage every turn.
- **Spoils of War.** Party pets are treated as your allies, and Skynet plays their turns.
- **Class identification.** When your Combat Extender setup gives an enemy a class or subclass identification passive, its tooltip shows the enemy's class and subclass.

---

## Settings (MCM → Skynet)

**Skynet Settings → General**

| Setting | What it does | Default |
|---|---|---|
| Enable Reactive Counter Statuses | Enemies gain situational counters against your repeated tactics | Off |
| Debug Logging | Shows Skynet's reasoning in the Script Extender console | On |
| Record each turn to a file that survives a crash | Keeps the last 30 turns in `Script Extender/skynet/turn_trace.txt`, for chasing crashes and freezes | Off |
| Movement diagnostics | Troubleshooting only: logs enemy positions and routes | Off |
| Enable Enemy Downed System | Death saves for living enemies | Off |
| Enable Party Downed Rules | Downed Condition 5E rules for your party | Off |
| Allow enemy Wildshape / Polymorph | Once per fight when on; removed when off | Off |
| Enable Enemy Buffs | Extra HP / Actions / Bonus Actions for enemies | Off |
| Enemy Buffs: scale with party size | Multiplies the buffs by party size ÷ 4 | Off |
| Enemy Buffs: extra max HP (%) | 0–100, steps of 5 | 0 |
| Enemy Buffs: extra Actions per turn | 0–3 | 0 |
| Enemy Buffs: extra Bonus Actions per turn | 0–3 | 0 |
| Passive Cap (Performance) | Limits how many spells Skynet evaluates for creatures with very many passives. 0 = off. Lower it on heavy mod lists | 20 |

**Skynet Settings → Adaptive Targeting (Intelligence/Wisdom)**

| Setting | What it does | Default |
|---|---|---|
| Enable Adaptive Targeting | Master switch for the learning described above | On |
| Intelligence Threshold | Intelligence needed to remember party members across the playthrough | 14 |
| Wisdom Threshold | Wisdom needed to notice who is hurting it this fight | 12 |
| Rounds Before This-Fight Awareness | Rounds before Wisdom enemies react | 4 |

**Auto Save tab:** Enable Skynet Auto Save (off), Warn about unsafe moments (on), the save triggers listed above, Timer length (10), Timer length is in seconds (off), and Settle time (3 seconds).

---

## Good to know

- Skynet plays enemy turns and the turns of NPC allies fighting beside you. It never plays your party members, your summons or modded companions you control.
- When Skynet has nothing sensible to do (nobody in reach, a target hidden, the enemy stuck), the base game AI plays that turn. That's on purpose.
- Debug Logging is on by default so you can see what Skynet is thinking in the Script Extender console. If you report a problem, the console lines starting with `[Skynet]` from that turn help a lot.
- Combat logs are saved per fight under `Script Extender/Skynet/` (`combat_*.json`).
---

## Repository layout

| Path | What it is |
|---|---|
| `Skynet/Mods/Skynet/ScriptExtender/Lua/Server/Skynet.lua` | The AI: turn planning, spell scoring, targeting, movement |
| `Skynet/Mods/Skynet/ScriptExtender/Lua/Server/SkynetGates.lua` | Concentration and "already affected" checks, AI archetype handling |
| `Skynet/Mods/Skynet/ScriptExtender/Lua/Server/SkynetAutoSave.lua` | The Auto Save system |
| `Skynet/Mods/Skynet/ScriptExtender/Lua/Server/Logging.lua` | Per-fight combat logs and the player profile |
| `Skynet/Mods/Skynet/ScriptExtender/Lua/Server/SkynetMoveDiag.lua`, `SkynetTrace.lua` | Troubleshooting tools (movement diagnostics, crash-safe turn trace) |
| `Skynet/Mods/Skynet/ScriptExtender/Lua/Server/CXHighLevelSlots.lua` | Level 7–9 bonus spell slots for Combat Extender |
| `Skynet/Mods/Skynet/MCM_blueprint.json` | The MCM settings menu |
| `Skynet/Public/Skynet/Stats/Generated/Data/` | Statuses and passives (downed systems, enemy buffs, class identification) |
| `tests/` | Smoke tests that load the real code into a simulated game (`tests/run_tests.ps1`, needs Lua 5.4) |
| `docs/` | Technical notes and the full maintenance history |

---

## Questions 

You can ask me questions at [https://rpghq.org/forums/viewtopic.php?t=6788-skynet](https://rpghq.org/forums/viewtopic.php?p=433622-skynet-7-0-baldur-s-gate-3) directly. (I advise you to not go through the forum itself as people there are unhinged)
