# ClassScanner

A World of Warcraft (3.3.5a) addon that tracks the races and classes of players you encounter.

## Installation

1. Copy the `ClassScanner` folder to your WoW installation's `Interface/AddOns` directory.
2. (Re)start the game.
3. Enable the addon in the character selection screen.

## Usage

The addon automatically scans players when:
1. You target them.
2. You mouse over them.
3. They perform any action in your combat log range (casting spells, taking damage, etc.).

Data is saved in the `ClassScannerDB` SavedVariable.

## License

This project is licensed under the GNU GPLv3 License - see the [LICENSE](LICENSE) file for details.

## Commands

- `/cs` or `/classscanner`: Opens a window showing the list of scanned players.
- `/cs clear`: Clears the database.
