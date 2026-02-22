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

When a player is first added to the database, the addon also records **where you first met them** (zone/subzone, and instance/BG name + type when applicable). This is stored once per player and shown in the UI list/tooltip.

The UI also shows a **per-class breakdown** (World/Dungeon/Battleground/etc.) in each class header row; hover the class header for the full breakdown.

Data is saved in the `ClassScannerDB` SavedVariable.

## Commands

- `/cs` or `/classscanner`: Opens a window showing the list of scanned players.
- `/cs clear`: Clears the database.

## License

This project is licensed under the GNU GPLv3 License - see the [LICENSE](LICENSE) file for details.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for a history of changes.
