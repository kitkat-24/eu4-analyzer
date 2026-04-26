import std/[algorithm, json, nre, os, parseopt, strutils, sequtils, sugar, sets,
            streams, strformat, tables, times, terminal]
# nimble packages
import malebolgia
import yaml
# Local modules
import tokenizer

const VANILLA_MODIFIER_CACHE = "vanilla_modifiers.json" # JSON is faster for large flat sets
const VANILLA_FLAG_CACHE = "vanilla_flags.json"

var definedModifiers = HashSet[string]()
var referencedModifiers = HashSet[string]()
var definedFunctions = Table[string, HashSet[string]]()
var definedFlags = HashSet[string]()
var referencedFlags = HashSet[string]()
var dynamicFlags = HashSet[string]()

let keyPattern = re"^[a-zA-Z]\w*$" # Must start with letter then contain letters, numbers, underscores
let tagPattern = re"^[A-Z]{3}$" # Match 3 uppercase letters
let modifierTrigger = re"^has\w+modifier$" # Find various has_X_modifer triggers
let flagTrigger = re"^has\w+flag$|^flag$" # Find various has_X_flag triggers
let flagEffect = re"^set\w+flag$" # Find various has_X_flag triggers
let macroPattern = re"\$\w+\$" # Find replace macros inside a modifier

# YAML parser type
type
  Config = object
    vanilla_root: string
    mod_root: string
    directories: seq[string]
    ignored: seq[string]
    # definitions: seq[string]
    # references: seq[string]

proc loadConfig(path: string): Config =
  var s = newFileStream(path, fmRead)
  if s == nil:
    quit("Could not find config YAML file: " & path)

  load(s, result)
  s.close()

# --- Logic for caching vanilla game keys ---
proc saveCache(keySet: HashSet[string], filename: string) =
  # 1. Convert the HashSet->Seq to a JsonNode using the % operator
  var list = keySet.toSeq()
  list.sort() # Sort for nicer reading
  let jsonNode = %list

  # 2. Write the stringified JSON to the file
  let f = open(filename, fmWrite)
  f.write(pretty(jsonNode)) # The $ operator turns the JsonNode into a string
  f.close()
  echo "Vanilla cache saved to ", filename

proc loadCache(filename: string): HashSet[string] =
  if fileExists(filename):
    var s = newFileStream(filename, fmRead)
    if s != nil:
      let data = parseJson(s)
      let keyList = to(data, seq[string])
      result = keyList.toHashSet()
      s.close()
      echo "Loaded ", result.len, " keys from vanilla cache."
    else:
      echo "Failed to open vanilla cache file!"
  else:
    echo "No vanilla cache found. Proceeding with mod-only keys."
    echo "Run with the -v flag to build the vanilla cache"

# --- Pass 1: Definitions ---
proc collectDefinitions(tokens: seq[Token], relPath: string) =
  var
    depth = 0 # Top-level scope
    currFunc = ""
  let
    modifierFile = contains(relPath, "modifier")
    scriptFile   = contains(relPath, "scripted")
  # const scopes = ["root", "effect", "trigger", "owner", ""]

  for i in 1..tokens.len-2:
    if tokens[i].lex[0] == '{':
      inc depth
    elif tokens[i].lex[0] == '}':
      dec depth
      if currFunc != "" and depth == 0: # Exited function def scope
        currFunc = ""
    # Found an expression
    elif tokens[i].lex[0] == '=':
      let left = tokens[i-1].lex
      let right = tokens[i+1].lex
      # Entering some kind of scope; might be a modifier or scripted function
      if right[0] == '{':
        # Modifier definition is its name, e.g. HUN_fort_defense = { ... }
        if modifierFile and depth == 0 and left.match(keyPattern).isSome:
          definedModifiers.incl(left)
        elif scriptFile and depth == 0 and left.match(keyPattern).isSome:
          definedFunctions[left] = HashSet[string]()
          currFunc = left
      # Regular expression, either "assignment" (effect; what we want) or "reference" (trigger; what we don't want (for now))
      else:
        # Flag is set like set_country_flag = HUN_my_cool_flag
        if left.match(flagEffect).isSome:
          if right.match(keyPattern).isSome:
            definedFlags.incl(right)
          # If we're in a function and find a macro (i.e. argument), record that
          elif currFunc != "":
            let m = right.match(macroPattern)
            if m.isSome:
              definedFunctions[currFunc].incl(m.get.match.replace("$", ""))
              let pattern = right.replace(re"\$.*?\$", "\\w+")
              dynamicFlags.incl("^" & pattern & "$")

# --- Pass 2: References ---
proc checkReferences(tokens: seq[Token], file, root: string, dynamicFlagRegexs: seq[Regex]) =
  let displayPath = relativePath(file, root)
  for i in 1..tokens.len-2:
    # Found an expression
    if tokens[i].lex[0] == '=':
      let left = tokens[i-1].lex
      let right = tokens[i+1].lex

      if right[0] == '{': # starting new scope, not a reference expression
        continue

      if left.match(modifierTrigger).isSome and right.match(keyPattern).isSome:
        # TODO: Catch $variables$ and error for other malformed modifier references
        if right notin definedModifiers:
          stdout.styledWriteLine(
            fgWhite, "Modifier missing definition: ", fgCyan, styleBright, right,
            resetStyle, fgWhite, " in ", displayPath, " at line ", $tokens[i+1].line, ": ", $tokens[i+1].col
          )
      elif left.match(flagTrigger).isSome and right.match(keyPattern).isSome:
        if right notin definedFlags:
          # Check all dynamic flags if not a static defined flag
          if not anyIt(dynamicFlagRegexs, right.match(it).isSome):
            stdout.styledWriteLine(
              fgWhite, "Flag missing definition: ", fgBlue, styleBright, right,
              resetStyle, fgWhite, " in ", displayPath, " at line ", $tokens[i+1].line, ": ", $tokens[i+1].col
            )

proc checkBraceScopes(tokens: seq[Token], displayPath: string) =
  var
    balance = 0
    scopeStart = newSeq[int](0)

  for i, tok in tokens:
    if tok.lex[0] == '{':
      inc balance
      scopeStart.add(tok.line)
    elif tok.lex[0] == '}':
      dec balance

      # Optimization: Catch immediate over-closing
      if balance < 0:
        # echo "Error: Extra '}' found at ", displayPath, ":", lineNum
        stdout.styledWriteLine(
          fgWhite, "Error: ", fgRed, styleBright, "Extra '}' ",
          resetStyle, fgWhite, " found at ", displayPath, " at line ", $tok.line, ": ", $tok.col
        )
        return # Stop early for this file, it's already broken

      # If we get here, know we won't error by popping from empty
      discard scopeStart.pop()

  if balance > 0:
    # echo "Error: Missing ", balance, " closing brace(s) '}' in ", displayPath, "\nLast scope started at:", scopeStart[0]
    stdout.styledWriteLine(
      fgWhite, "Error: ", fgRed, styleBright, "Missing ", $balance, " closing brace(s) '}' ",
      resetStyle, fgWhite, " in ", displayPath, "\nLast scope started at line ", $scopeStart[0]
    )

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
if not vanillaMode and fileExists(VANILLA_MODIFIER_CACHE) and fileExists(VANILLA_FLAG_CACHE):
  definedModifiers = loadCache(VANILLA_MODIFIER_CACHE)
  definedFlags = loadCache(VANILLA_FLAG_CACHE)
# 2. Else process vanilla cache
else:
  for dir in config.directories:
    let path = joinPath(config.vanilla_root, dir)
    if not validPath(path):
      continue

    echo "\nScanning directory for definitions: ", path
    for file in walkDirRec(path):
      let displayPath = relativePath(file, config.mod_root)
      if file.endsWith(".txt"):
        let tokens = tokenize(readEu4(file))
        collectDefinitions(tokens, displayPath)

  saveCache(definedModifiers, VANILLA_MODIFIER_CACHE)
  saveCache(definedFlags, VANILLA_FLAG_CACHE)
  echo "\nVanilla processing complete. Cache saved.\n-------------------------------\n"


# First pass through files
proc token_pass(file, displayPath: string): seq[Token] {.gcsafe.} =
  let tokens = tokenize(readEu4(file))
  checkBraceScopes(tokens, displayPath)
  return tokens

echo "Scanning directories for definitions..."
let start = cpuTime()

# Collect files
let files = collect:
  for dir in config.directories:
    let path = joinPath(config.mod_root, dir)
    if not validPath(path):
      continue
    for file in walkDirRec(path):
      let displayPath = relativePath(file, config.mod_root)
      if file.endsWith(".txt") and displayPath notin config.ignored:
        file

var parsedTokenSeq = newSeq[seq[Token]](files.len)

# Create a 'master' scope
# This ensures all spawned tasks finish before code continues past the block
var m = createMaster()
m.awaitAll:
  for i, file in files:
    let displayPath = relativePath(file, config.mod_root)
    m.spawn token_pass(file, displayPath) -> parsedTokenSeq[i]


echo &"Tokenized in: {(cpuTime() - start) * 1000:.3f} ms"


if onlyBraces:
  echo "Braces check only; done!"
  quit(0)


# First parser pass: store definitions
for i, tokens in parsedTokenSeq:
  let displayPath = relativePath(files[i], config.mod_root)
  collectDefinitions(tokens, displayPath)

let dynamicFlagRegexs = collect:
  for item in dynamicFlags: re(item)

# Second parser pass: check references
for i, tokens in parsedTokenSeq:
  let file = files[i]
  checkReferences(tokens, file, config.mod_root, dynamicFlagRegexs)

echo "\nDone!"
