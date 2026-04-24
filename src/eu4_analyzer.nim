import std/[json, jsonutils, nre, os, parseopt, strutils, sequtils, sets, streams]
import yaml

const CACHE_FILE = "vanilla_keys.json" # JSON is faster for large flat sets
var definedKeys = HashSet[string]()
var referencedKeys = HashSet[string]()

let keyPattern = re"[a-zA-Z]\w*" # Must start with letter then contain letters, numbers, underscores
let tagPattern = re"[A-Z]{3}" # Match 3 uppercase letters
let modifierTrigger = re"^has\w+modifier$" # Find various has_X_modifer triggers

# YAML parser type
type
  Config = object
    vanilla_root: string
    mod_root: string
    definitions: seq[string]
    references: seq[string]

proc loadConfig(path: string): Config =
  var s = newFileStream(path, fmRead)
  if s == nil:
    quit("Could not find config YAML file: " & path)

  load(s, result)
  s.close()

# --- Logic for caching vanilla game keys ---
proc saveCache(keySet: HashSet[string]) =
  # 1. Convert the HashSet->Seq to a JsonNode using the % operator
  let jsonNode = %(keySet.toSeq())

  # 2. Write the stringified JSON to the file
  let f = open(CACHE_FILE, fmWrite)
  f.write(pretty(jsonNode)) # The $ operator turns the JsonNode into a string
  f.close()
  echo "Vanilla cache saved to ", CACHE_FILE

proc loadCache() =
  if fileExists(CACHE_FILE):
    var s = newFileStream(CACHE_FILE, fmRead)
    if s != nil:
      let data = parseJson(s)
      let keyList = to(data, seq[string])
      definedKeys = keyList.toHashSet()
      s.close()
      echo "Loaded ", definedKeys.len, " keys from vanilla cache."
    else:
      echo "Failed to open vanilla cache file!"
  else:
    echo "No vanilla cache found. Proceeding with mod-only keys."
    echo "Run with the -v flag to build the vanilla cache"

# --- Pass 1: Definitions ---
proc collectDefinitions(file: string) =
  for line in lines(file):
    let cleanLine = line.split('#')[0].strip()
    if "=" in cleanLine:
      # Basic logic: everything before '=' is a key definition
      let key = cleanLine.split('=')[0].strip()
      if key.match(keyPattern).isSome:
        definedKeys.incl(key)

# --- Pass 2: References ---
proc checkReferences(file: string) =
  var lineNum = 0
  for line in lines(file):
    lineNum.inc()
    let cleanLine = line.split('#')[0].strip()
    # Logic to find references (this depends on your specific script syntax)
    # If the key appears on the right side of an '=', it's a reference
    if "=" in cleanLine:
      let words = cleanLine.split('=')
      let operator = words[0].strip()

      if words.len < 2 or operator.match(modifierTrigger).isNone:
        continue

      let key = words[1].strip()
      if key.match(tagPattern).isSome or key.match(keyPattern).isNone:
        continue
      if key notin definedKeys:
          echo "Missing Definition: ", key, " in ", file, " at line ", lineNum

proc checkBraceScopes(filePath: string) =
  var
    balance = 0
    lineNum = 0
    inString = false
    scopeStart = newSeq[int](0)

  for line in lines(filePath):
    inc lineNum
    # 1. Strip comments immediately
    let activeCode = line.split('#')[0]

    for i, c in activeCode:
      # 2. Handle quoted strings
      if c == '"':
        inString = not inString
        continue

      if not inString:
        # 3. The actual counting
        if c == '{':
          inc balance
          scopeStart.add(lineNum)
        elif c == '}':
          dec balance

          # Optimization: Catch immediate over-closing
          if balance < 0:
            echo "Error: Extra '}' found at ", filePath, ":", lineNum
            return # Stop early for this file, it's already broken

          # If we get here, know we won't error by popping from empty
          discard scopeStart.pop()

  if balance > 0:
    echo "Error: Missing ", balance, " closing brace(s) '}' in ", filePath, "\nLast scope started at:", scopeStart[0]
  elif balance == 0:
    # echo filePath, " is scope-safe."
    discard

proc validPath(dirPath: string): bool =
  result = true
  if not dirExists(dirPath):
    echo "Error: Directory '" & dirPath & "' does not exist."
    result = false


# Entry point logic
var configFile = "config.yaml"
var onlyBraces = false
var vanillaMode = false


# Parse arguments
var p = initOptParser()
for kind, key, val in p.getopt():
  case kind
  of cmdLongOption, cmdShortOption:
    case key
    of "braces", "b": onlyBraces = true
    of "vanilla", "v": vanillaMode = true
    # Add future flags here
  of cmdArgument:
    configFile = key # The first non-flag argument is our config path
  of cmdEnd: assert(false) # Should not happen


let config = loadConfig(configFile)

# 1. Load vanilla cache if we aren't rebuilding it
if not vanillaMode:
  loadCache()
# 2. Else process vanilla cache
else:
  for dir in config.definitions:
    let path = joinPath(config.vanilla_root, dir)
    if not validPath(path):
      continue

    echo "Scanning directory: ", path
    for file in walkDirRec(path):
      if file.endsWith(".txt"):
        collectDefinitions(file)

  saveCache(definedKeys)
  echo "Vanilla processing complete."
  quit(0)

# First pass through files
for dir in config.definitions:
  let path = joinPath(config.mod_root, dir)
  if not validPath(path):
    continue

  echo "Scanning directory: ", path
  for file in walkDirRec(path):
    if file.endsWith(".txt"):
      if file.endsWith(".txt"):
        if onlyBraces:
          checkBraceScopes(file)
        else: # Run everything
          collectDefinitions(file)
          checkBraceScopes(file)

# Second parser pass
if not onlyBraces:
  for dir in config.references:
    let path = joinPath(config.mod_root, dir)
    if not validPath(path):
      continue

    echo "Scanning directory: ", path
    for file in walkDirRec(path):
      if file.endsWith(".txt"):
        checkReferences(file)

echo "Done!"