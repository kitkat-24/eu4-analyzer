# EU4 Mission Viewer README

## Overview
The `mission_viewer` is a Nim utility that parses *Europa Universalis IV* (EU4) mission files to generate SVG visualizations of mission trees. It can display defined mission title localization, branching mission options, and marks missions with `has_country_shield = yes`.

## Usage
Run the tool from the command line by providing the mission file path and desired options:

```bash
./mission_viewer [mission_file] [options]
```

---

## Command-Line Arguments

| Flag / Argument | Description |
| :--- | :--- |
| `mission_file` | **Required.** The path to the EU4 `.txt` mission script. Must be the first non-flag argument. |
| `-l`, `--locFile` | Path to the `.yml` localization file. If provided, the tool will replace mission ids with the `mission_name_title` loc strings. |
| `-b`, `--browser` | A boolean flag. When present, automatically opens the resulting SVG in your default web browser. |
| `-d`, `--depth` | An integer value used to filter which missions to display in a branching slot. Defaults to `0`. |
| `-h`, `--help` | Displays the basic usage help message. |

---

## Examples

### Standard View
```bash
./mission_viewer missions/my_mod_missions.txt
```

### Full Feature View
View localized missions and automatically open the browser:
```bash
./mission_viewer missions/my_mod_missions.txt --locFile:loc/english.yml --browser
```

### View Branching Path
Visualize the the first branching path of the tree (default shows the branching path preview/placeholders):
```bash
./mission_viewer missions/branching_tree.txt -d:1
```