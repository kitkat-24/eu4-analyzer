import std/[algorithm, json, nre, os, parseopt, strutils, sequtils, sugar, sets,
            streams, strformat, tables, times, terminal]
# nimble packages
import malebolgia
import yaml
# Local modules
import tokenizer

const VANILLA_MODIFIER_CACHE = "vanilla_modifiers.json" # JSON is faster for large flat sets
const VANILLA_FLAG_CACHE = "vanilla_flags.json"


type
  # YAML parser type
  Config = object
    vanilla_root: string
    mod_root: string
    directories: seq[string]
    ignored: seq[string]
    # definitions: seq[string]
    # references: seq[string]
  FuncDef = ref object
    file: string
    line: int
    name: string
    definedFlags: seq[string]
  FuncCall = object
    name: string
    args: seq[(string, string)]


var definedModifiers = HashSet[string]()
var referencedModifiers = HashSet[string]()
var definedFlags = HashSet[string]()
var referencedFlags = HashSet[string]()
var dynamicFlags = HashSet[string]()
var funcs = Table[string, FuncDef]()
var funcCalls = newSeq[FuncCall]()

let keyPattern = re"^[a-zA-Z]\w*$" # Must start with letter then contain letters, numbers, underscores
let tagPattern = re"^[A-Z]{3}$" # Match 3 uppercase letters
let modifierTrigger = re"^has\w+modifier$" # Find various has_X_modifer triggers
let flagTrigger = re"^has\w+flag$|^flag$" # Find various has_X_flag triggers
let flagEffect = re"^set\w+flag$" # Find various has_X_flag triggers
let macroPattern = re"\$\w+\$" # Find replace macros inside a modifier

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
    currentFunction: FuncDef # Tracks the name of the enclosing function def
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
        # Track macro arguments used in functions
        if ctx.currentFunction != nil and e.right.contains("$"):
          ctx.currentFunction.definedFlags.add(e.right)
        else:
          definedFlags.incl(e.right)
      elif ctx.currentFunction != nil and e.left.match(flagTrigger) and e.right.contains("$"):
        ctx.currentFunction.def

    of scoped:
      # --- Handle Scope Entry ---
      var nextCtx = ctx # Copy the current context
      nextCtx.depth += 1

      if ctx.depth == 0:
        # We are at the root; check if this is a definition
        if ctx.isModifierFile:
          definedModifiers.incl(e.name)
        elif ctx.isScriptFile:
          nextCtx.currentFunction = FuncDef(name: e.name, line: e.line, file: ctx.relPath)

      # Recurse into children with the updated context
      collectDefinitions(e.children, nextCtx)

      let f = nextCtx.currentFunction
      if f != nil and ctx.depth == 0:
        if f.name in funcs:
          printLineError(fmt"Redefinition of function {f.name}", ctx.relPath, e.line, e.col)
        else:
          funcs[f.name] = f

proc collectFuncCalls(expressions: seq[Expr]) =
  for e in expressions:
    if e.kind == scoped:
      # If this function name has been defined and all chilren are expressions,
      # hopefully it's a function call of the form:
      # custom_trigger = { tag = FOO religion = mr_cathar }
      if e.name in funcs and all(e.children, c => c.kind == expression):
        for c in e.children:
          let dyn_str = fmt"${c.left}$"
          for flag in filter(funcs[e.name].definedFlags, s => s.contains(dyn_str)):
            definedFlags.incl(flag.replace(dyn_str, c.right))
      else:
        collectFuncCalls(e.children)


# --- Pass 2: References ---
proc checkReferences(expressions: seq[Expr], ctx: Context) =
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
          printLineError(fmt"Flag {e.right} missing definition", ctx.relPath, e.line, e.col)
          # stdout.styledWriteLine(
          #   fgWhite, "Flag missing definition: ", fgBlue, styleBright, right,
          #   resetStyle, fgWhite, " in ", displayPath, " at line ", $tokens[i+1].line, ": ", $tokens[i+1].col
          # )

    of scoped:
      # Recurse into children with the same context
      checkReferences(e.children, ctx)

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
    let displayPath = relativePath(file, config.vanilla_root)
    let initialCtx = initContext(displayPath)
    collectDefinitions(vanillaDSTs[i], initialCtx)
  for dst in vanillaDSTs:
    collectFuncCalls(dst)

  # Clear for mod overwrites to not trigger redefinition error
  funcs.clear()

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
for dst in modDSTs:
  collectFuncCalls(dst)

# Second parser pass: check references
for i, exprs in modDSTs:
  let initialCtx = initContext(relativePath(files[i], config.mod_root))
  checkReferences(exprs, initialCtx)

echo "\nDone!"
