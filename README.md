# ClassScanner

A World of Warcraft (3.3.5a) addon that tracks the classes(and other statistics) of players you encounter.

## Installation

1. Copy the `ClassScanner` folder to your WoW installation's `Interface/AddOns` directory.
2. (Re)start the game.
3. Enable the addon in the character selection screen.
4. If you are updating the addon, simply copy as you did before and type `/reload` from the ingame chat.

## Usage

The addon automatically scans players when:

1. You target them.
2. You mouse over them.
3. They perform any action in your combat log range (casting spells, taking damage, etc.).
4. You have friendly nameplates enabled.

Nameplate scans retry missing level data briefly, so players whose plates appear before the client resolves full unit info are more likely to get a level recorded automatically.

When a player is first added to the database, the addon also records **where you first met them** (zone/subzone, and instance/BG name + type when applicable). This is stored once per player and shown in the UI list/tooltip.

The UI also shows a **per-class breakdown** (World/Dungeon/Battleground/etc.) in each class header row; hover the class header for the full breakdown.

### Battleground breakdowns

- Use the **Location** filter and select **Battleground** to see a full class distribution and list for players who have ever been detected in a battleground.
- A player's **First Met** location text is still recorded once when they are first added to the database; it may show a non-BG zone even if they were later seen in a BG.
- The **Top BG Class** stat card shows the most common class in the Battleground bucket for the current filters; hover it for a full per-class count breakdown.

Data is saved in the `ClassScannerDB` SavedVariable.

### Specialization Detection

On Ascension Bronzebeard (original 9 classes), ClassScanner now tracks a best-known specialization for each player.

Detection sources are layered from highest confidence to lowest:

1. Talent trees for your own character.
2. Talent inspection for your current target.
3. Obvious buff/aura signals (stances/forms/presences/shields).
4. Combat-log spell heuristics (distinctive spec abilities).

The UI shows detected spec beside race, and includes a **Spec** dropdown filter.
Row tooltips also show the detected spec, detection source, and confidence.

### Granular data resets

- The main window now has a **Data Reset** button next to **Reset** and **Backup**.
- **Reset** still only clears UI filters/search/sort. It does not delete saved data.
- **Data Reset** opens destructive actions for specific stat families:
  - **Full Reset** removes all saved player records from `ClassScannerDB`.
  - **Reset Top Spec Data** clears stored specialization fields while keeping player records.
  - **Reset Battleground Data** removes battleground evidence; entries first met in a battleground are removed because that evidence cannot be cleared more narrowly.
  - **Reset World Data** removes entries first met in the open world.
  - **Reset Current Class Data** appears when a class filter is active and removes entries for that class.
  - **Reset Current Spec Data** appears when a concrete spec filter is active and clears spec fields for players currently mapped to that spec.
- Clicking the **Top Spec** stat card opens the confirmation dialog for the global Top Spec reset directly.
- Every destructive data reset creates a backup first and asks for confirmation before applying changes.

### Combat Damage Tracking

The addon tracks damage dealt to you by other players (PvP). For each attacker it records:

- **Total damage** dealt to you (lifetime, across all encounters).
- **Hardest single hit** — the biggest damage event, including the spell/attack name and whether it was a critical strike.
- **Peak burst DPS** — the highest damage-per-second in a configurable sliding window (default 3 seconds).

Pet and guardian damage is attributed to the owner when a SPELL_SUMMON event has been observed.

View rankings via the **Sort** dropdown in the `/cs` UI (Most Damage / Hardest Hit / Max Burst DPS), or use `/cs topdmg` and `/cs topclassdmg` in chat. Hover any player row to see their combat stats in the tooltip.

## Commands

- `/cs` or `/classscanner`: Opens a window showing the list of scanned players.
- `/cs clear`: Clears the database.
- `/cs topdmg [n]`: Prints the top N players (default 10) by total damage dealt to you.
- `/cs topclassdmg [n]`: Prints the top N classes (default 10) by total damage dealt to you.
- `/cs dmg on|off`: Toggle combat damage tracking.
- `/cs burst <sec>`: Set burst DPS sliding window (1-30 seconds, default 3).
- `/cs dmgclear`: Clear all combat data without removing scanned player records.
- `/cs quiet`: Toggle "New player scanned" chat prints.
- `/cs throttle <sec>`: Set print throttle.
- `/cs search <term>`: Search the DB (also fills the UI search box if the UI is open).
- `/cs refresh`: Refresh the UI (if open).
- `/cs backup [reason]`: Create a DB backup (SavedVariables).
- `/cs backups`: List available backups.
- `/cs restore <id|latest> confirm`: Restore a backup (overwrites current DB and reloads the UI).

## Backups

ClassScanner can create in-game backups of your database (stored in SavedVariables) in case of corruption or accidental clears.

- UI: Click the **Backup** button in the main window (next to **Reset**).
- Data resets: Use the **Data Reset** button for targeted destructive clears; a backup is created automatically before changes are applied.
- Chat: Use `/cs backup`.
- Restore: Use `/cs restore latest confirm` (this reloads the UI).

## License

This project is licensed under the GNU GPLv3 License - see the [LICENSE](LICENSE) file for details.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for a history of changes.
