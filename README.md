# Flipper

A small World of Warcraft: Forever add-on that keeps a notebook of what you
bought at the auction house and shows whether the price has gone up or down
since.

Requires [Auctionator](https://www.curseforge.com/wow/addons/auctionator).
Flipper does not scan the auction house itself; it reads the prices from
Auctionator's last scan.

## What it does

- Logs every auction house **buyout** (not bids, not sales), per character.
- `/flip` opens a table: date, item, amount, paid, price per piece, current
  price per piece and the change in percent.
- After each Auctionator full scan it records the price of about 380 crafting
  reagents and of everything you have bought. Hover a row to see how the
  price developed.
- Search box with suggestions from your own log. While searching, the bottom
  line shows how many pieces you bought, what you paid and your average price.
- Resizable window, font size, scale and background opacity under *Settings*.
- A small X on each row deletes it. Hold Ctrl (changeable) to skip the
  confirmation.

## Commands

| Command | What it does |
| --- | --- |
| `/flip` or `/flipper` | open or close the table |
| `/flip snapshot` | record current Auctionator prices now |
| `/flip font 8-20` | font size |
| `/flip scale 60-160` | window scale in percent |
| `/flip quickdelete ctrl/shift/alt/off` | key that skips the delete confirmation |
| `/flip reset` | reset window size, position and settings |

## Install

Get it from CurseForge, or download a release from this repository and unzip
it into `World of Warcraft/_forever_/Interface/AddOns`, so that the folder
`AddOns/Flipper` contains `Flipper.toc`.

## Releases

Every change merged into `main` that raises `## Version:` in `Flipper.toc` is
tagged, packaged and published by `.github/workflows/release.yml`, as a GitHub
release and on CurseForge.

## License

MIT, see [LICENSE](LICENSE).
