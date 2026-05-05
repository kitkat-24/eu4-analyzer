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

# Context object used for definition recursion
type
  Context = object
    relPath: string
    isModifierFile: bool
    isScriptFile: bool
    currentFunction: string # Tracks the name of the enclosing function def
    depth: int
proc initContext(relPath: string): Context =
  Context(relPath: relPath, isModifierFile: contains(relPath, "modifier"), isScriptFile: contains(relPath, "scripted"))

# --- Pass 1: Definitions ---
proc collectDefinitions(expressions: seq[Expr], ctx: Context) =
  for e in expressions:
    case e.kind
    of expression:
      # --- Handle Regular Assignments ---
      # Example: set_country_flag = HUN_my_cool_flag
      # Regular expression, either "assignment" (effect; what we want) or
      # "reference" (trigger; what we don't want (for now))
      # Flag is set like set_country_flag = HUN_my_cool_flag
      if e.left.match(flagEffect).isSome:
        definedFlags.incl(e.right)

        # Track macro arguments used in functions
        if ctx.currentFunction != "" and e.right.contains("$"):
          let macroName = e.right.replace("$", "")
          definedFunctions[ctx.currentFunction].incl(macroName)
              # let m = right.match(macroPattern)
              # if m.isSome:
              #   definedFunctions[currFunc].incl(m.get.match.replace("$", ""))
              #   let pattern = right.replace(re"\$.*?\$", "\\w+")
              #   dynamicFlags.incl("^" & pattern & "$")

    of scoped:
      # --- Handle Scope Entry ---
      var nextCtx = ctx # Copy the current context
      nextCtx.depth += 1

      if ctx.depth == 0:
        # We are at the root; check if this is a definition
        if ctx.isModifierFile:
          definedModifiers.incl(e.name)
        elif ctx.isScriptFile:
          definedFunctions[e.name] = HashSet[string]()
          nextCtx.currentFunction = e.name # Record that children are inside this function

      # Recurse into children with the updated context
      collectDefinitions(e.children, nextCtx)

# --- Pass 2: References ---
proc checkReferences(expressions: seq[Expr], ctx: Context, dynamicFlagRegexs: openArray[Regex]) =
  for e in expressions:
    case e.kind
    of expression:
      # Should we enforce that right matches keyPattern?
      if e.left.match(modifierTrigger).isSome:
        # TODO: Catch $variables$ and error for other malformed modifier references
        if e.right notin definedModifiers:
          printLineError(fmt"Modifier {e.right} missing definition", ctx.relPath, e.line, e.col)
          # stdout.styledWriteLine(
          #   fgWhite, "Modifier missing definition: ", fgCyan, styleBright, right,
          #   resetStyle, fgWhite, " in ", ctx.relPath, " at line ", $tokens[i+1].line, ": ", $tokens[i+1].col
          # )
      # Should we enforce that right matches keyPattern?
      elif e.left.match(flagTrigger).isSome:
        if e.right notin definedFlags:
          # Check all dynamic flags if not a static defined flag
          if not anyIt(dynamicFlagRegexs, e.right.match(it).isSome):
            printLineError(fmt"Flag {e.right} missing definition", ctx.relPath, e.line, e.col)
            # stdout.styledWriteLine(
            #   fgWhite, "Flag missing definition: ", fgBlue, styleBright, right,
            #   resetStyle, fgWhite, " in ", displayPath, " at line ", $tokens[i+1].line, ": ", $tokens[i+1].col
            # )

    of scoped:
      # Recurse into children with the same context
      checkReferences(e.children, ctx, dynamicFlagRegexs)

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

proc collectFilesInDirs(root: string, directories, ignored: seq[string]): seq[string] =
  collect:
    for dir in directories:
      let path = joinPath(root, dir)
      if not validPath(path):
        continue
      for file in walkDirRec(path):
        let displayPath = relativePath(file, root)
        if file.endsWith(".txt") and displayPath notin ignored:
          file

# Processing of individual file
proc token_pass(file, displayPath: string): seq[Expr] {.gcsafe.} =
  let tokens = tokenize(readEu4(file))
  result = buildDST(tokens, displayPath)


let config = loadConfig(configFile)
# Create a 'master' scope
# This ensures all spawned tasks finish before code continues past the block
var m = createMaster()

# 1. Load vanilla cache if we aren't rebuilding it
if not vanillaMode and fileExists(VANILLA_MODIFIER_CACHE) and fileExists(VANILLA_FLAG_CACHE):
  definedModifiers = loadCache(VANILLA_MODIFIER_CACHE)
  definedFlags = loadCache(VANILLA_FLAG_CACHE)
# 2. Else process vanilla cache
else:
  let vanillaFiles = collectFilesInDirs(config.vanilla_root, config.directories, config.ignored)
  var vanillaDSTs = newSeq[seq[Expr]](vanillaFiles.len)
  echo fmt"Scanning vanilla files in {config.vanilla_root}..."
  let vanillaStart = cpuTime()

  # Read & parse DST in parallel
  m.awaitAll:
    for i, file in vanillaFiles:
      let displayPath = relativePath(file, config.vanilla_root)
      m.spawn token_pass(file, displayPath) -> vanillaDSTs[i]

  # Do simpler definition check in sequence
  for i, file in vanillaFiles:
    let dst = vanillaDSTs
    let displayPath = relativePath(file, config.vanilla_root)
    let initialCtx = initContext(displayPath)
    collectDefinitions(vanillaDSTs[i], initialCtx)

  echo &"Tokenized in: {(cpuTime() - vanillaStart) * 1000:.3f} ms"

  saveCache(definedModifiers, VANILLA_MODIFIER_CACHE)
  saveCache(definedFlags, VANILLA_FLAG_CACHE)
  echo "\nVanilla processing complete. Cache saved.\n-------------------------------\n"


echo "Scanning directories for definitions..."
let start = cpuTime()

# Collect files
let files = collectFilesInDirs(config.mod_root, config.directories, config.ignored)

var modDSTs = newSeq[seq[Expr]](files.len)

m.awaitAll:
  for i, file in files:
    let displayPath = relativePath(file, config.mod_root)
    m.spawn token_pass(file, displayPath) -> modDSTs[i]


echo &"Tokenized in: {(cpuTime() - start) * 1000:.3f} ms"


if onlyBraces:
  echo "Braces check only; done!"
  quit(0)


# First parser pass: store definitions
for i, exprs in modDSTs:
  let initialCtx = initContext(relativePath(files[i], config.mod_root))
  collectDefinitions(exprs, initialCtx)

let dynamicFlagRegexs = collect:
  for item in dynamicFlags: re(item)

# Second parser pass: check references
for i, exprs in modDSTs:
  let initialCtx = initContext(relativePath(files[i], config.mod_root))
  checkReferences(exprs, initialCtx, dynamicFlagRegexs)

echo "\nDone!"
