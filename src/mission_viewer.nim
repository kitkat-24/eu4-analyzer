## Visualize EU4 mission trees
import std/[browsers, os, parseopt, sequtils, sugar, streams, strformat, strutils, tables, unicode]
import yaml
# Local modules
import tokenizer

type
  Mission = object
    name: string
    column: int
    row: int
    parents: seq[string]

proc `$`*(m: Mission): string =
  # Uses a bracketed format: [R1:C2] MissionName (<- Parent1, Parent2)
  let parentList = if m.parents.len > 0: " <- " & m.parents.join(", ") else: ""
  fmt"[{m.row}:{m.column}] {m.name}{parentList}"

proc parseMissions(tokens: seq[Token]): seq[Mission] =
  var
    currentCol = 0
    currentMission: Mission
    bracketLevel = 0
    inSeries = false

  for i, t in tokens:
    case t.lex
    of "{":
      inc bracketLevel
      if bracketLevel == 2: # Entered new mission def
        currentMission = Mission(name: tokens[i-2].lex, column: currentCol)
    of "}":
      dec bracketLevel
      if bracketLevel == 1: # Exited mission def
        result.add(currentMission)
    of "slot":
      currentCol = tokens[i+2].lex.parseInt # simplified
    of "position":
      currentMission.row = tokens[i+2].lex.parseInt
    of "required_missions":
      var j = i + 3
      while tokens[j].lex != "}":
        currentMission.parents.add(tokens[j].lex)
        inc j
    else: discard

proc generateMonospaceText(name:string, x, y, w, h: int): string =
  # CSS Font stack: Consolas is first, then generic monospace
  let fontStack = "Consolas, 'Liberation Mono', Menlo, Courier, monospace"

  fmt"""
  <foreignObject x="{x}" y="{y}" width="{w}" height="{h}">
    <div xmlns="http://www.w3.org/1999/xhtml" style="
      display: flex;
      align-items: center;
      height: 100%;
      width: 100%;
      color: #e0e0e0;
      font-family: {fontStack};
      font-size: 16px;
      line-height: 1.1;
      text-align: center;
      word-wrap: break-word;
      overflow: hidden;
      padding: 10px;
      box-sizing: border-box;
      text-justify: auto;
    ">
      {name}
    </div>
  </foreignObject>
  """

proc getSvgHeader(): string =
  # This includes the arrowhead definition
  let
    l = 6.0 # Arrowhead length
    w = 4.0 # Arrowhead width
  result = fmt"""
    <defs>
      <marker id="arrowhead" markerWidth="{l}" markerHeight="{w}"
              refX="{l}" refY="{w/2}" orient="auto">
        <polygon points="0 0, {l} {w/2}, 0 {w}" fill="#888" />
      </marker>
    </defs>
  """

proc generateConnectors(x1, y1, x2, y2: int): string =
  let
    midY = y1 + ((y2 - y1) div 2)
    radius = 20 # The "roundness" of the curve

  # SVG Path Logic:
  # M = Move to start
  # L = Line to just before the turn
  # Q = Curve using the corner as a control point to the horizontal lane
  # L = Line across the horizontal lane
  # Q = Curve down to the vertical drop
  if x1 == x2: # No curve
    result = fmt"""
    <path d="M {x1} {y1}
             L {x2} {y2}"
          fill="none"
          stroke="#888"
          stroke-width="4"
          marker-end="url(#arrowhead)" />
    """
  else:
    result = fmt"""
    <path d="M {x1} {y1}
             L {x1} {midY-radius}
             Q {x1} {midY} {x1 + (if x2 > x1: radius else: -radius)} {midY}
             L {x2 + (if x2 > x1: -radius else: radius)} {midY}
             Q {x2} {midY} {x2} {midY + radius}
             L {x2} {y2}"
          fill="none"
          stroke="#888"
          stroke-width="4"
          marker-end="url(#arrowhead)" />
    """

proc generateSvg(missions: seq[Mission], filename: string, locKeys: Table[string, string]) =
  let
    boxWidth = 150
    boxHeight = 80
    colPad = 25
    rowPad = 40
    colWidth = 2*colPad + boxWidth
    rowHeight = 2*rowPad + boxHeight
    textPad = 10

  let maxRow = missions.mapIt(it.row).max()
  var svgContent = fmt"<svg xmlns='http://www.w3.org/2000/svg' width='{colWidth*5}' height='{rowHeight*maxRow}' style='background: #eeeeee;'>"
  svgContent.add getSvgHeader() # Adds arrowhead definition for connectors

  let missionLocs = collect:
    for m in missions: {m.name: ((m.column-1)*colWidth + colPad, (m.row-1)*rowHeight + rowPad)}

  for m in missions:
    let (x,y) = missionLocs[m.name]

    # Draw a simple mission box
    svgContent.add fmt"""
      <rect x='{x}' y='{y}' width='{boxWidth}' height='{boxHeight}' rx='5' fill='#4a90e2' />
    """
    let name = locKeys.getOrDefault(m.name & "_title", m.name)
    svgContent.add generateMonospaceText(name, x, y, boxWidth, boxHeight)

    let (x2, y2) = (x + boxWidth div 2, y)
    for p in m.parents:
      let (x1, startY) = (missionLocs[p][0] + boxWidth div 2, missionLocs[p][1] + boxHeight)
      svgContent.add generateConnectors(x1, startY, x2, y2)

  svgContent.add "</svg>"
  writeFile(filename, svgContent)


if isMainModule:
  var
    p = initOptParser()
    missionFile = ""
    locFile = ""

  for kind, key, val in p.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "help", "h": echo "Usage: mission-viewer path/to/missions.txt [-l/--locFile path/to/loc.yml]"
      of "locFile", "l": locFile = val
      # Add future flags here
    of cmdArgument:
      missionFile = key # The first non-flag argument is our config path
      # Only set missionFile if it's currently empty to avoid
      # capturing trailing whitespace or unintended args
      # if missionFile == "":
      #   missionFile = key
    of cmdEnd: assert(false) # Should not happen

  assert missionFile != "", "Mission file must be given as the first argument!"
  assert missionFile.fileExists, "Cannot find file: " & missionFile

  echo "Parsing Mission: ", missionFile
  echo "Using Loc: ", (if locFile == "": "None" else: locFile)

  var locKeys = initTable[string, string]()
  if locFile != "":
    if not locFile.fileExists():
      quit("Could not find localization file: " & locFile)
    let rawtext = readEu4(locFile)
    for line in rawtext.splitLines:
      let bits = filter(map(line.split(":"), s => s.strip()), s => s.len > 0)
      if bits.len > 1 and bits[0][0] != '#':
        # Have to strip quotation marks off
        locKeys[bits[0]] = bits[1][1..<bits[1].len-1]

  let tokens = tokenize(readEu4(missionFile))
  let missions = parseMissions(tokens)

  let outFile = "missions.svg"
  generateSvg(missions, outFile, locKeys)
  let path = outFile.absolutePath()
  # openDefaultBrowser("file://" & path)

