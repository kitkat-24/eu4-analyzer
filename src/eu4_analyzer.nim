import nre, os, strutils, sets, streams, yaml

var definedKeys = initHashSet[string]()
var referencedKeys = initHashSet[string]()

let keyPattern = re"[a-zA-Z]\w*" # Must start with letter then contain letters, numbers, underscores
let tagPattern = re"[A-Z]{3}" # Match 3 uppercase letters
let modifierTrigger = re"^has\w+modifier$" # Find various has_X_modifer triggers

# YAML parser type
type
  Config = object
    mod_root: string
    definitions: seq[string]
    references: seq[string]

proc loadConfig(path: string): Config =
  var s = newFileStream(path, fmRead)
  if s == nil:
    quit("Could not find config YAML file: " & path)

  load(s, result)
  s.close()

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



proc processFiles(dirPath: string) =
  # Check if the directory actually exists first
  if not dirExists(dirPath):
    echo "Error: Directory '" & dirPath & "' does not exist."
    quit(1)


  # walkDirRec yields files one by one
  for file in walkDirRec(dirPath):
    # Filter for .txt files
    if file.endsWith(".txt"):
      try:
        echo "Processing: ", file

        # This is where your processing logic goes
        let content = readFile(file)
        # Example: echo "File size: ", content.len
        echo "File found: ", file

      except IOError:
        echo "Could not read file: ", file

# Entry point logic
var configFile = "config.yaml"
if paramCount() > 1:
  configFile = paramStr(1)

let config = loadConfig(configFile)
for dir in config.definitions:
  let path = joinPath(config.mod_root, dir)
  if not validPath(path):
    continue

  echo "Scanning directory: ", path
  for file in walkDirRec(path):
    if file.endsWith(".txt"):
      collectDefinitions(file)
      checkBraceScopes(file)

for dir in config.references:
  let path = joinPath(config.mod_root, dir)
  if not validPath(path):
    continue

  echo "Scanning directory: ", path
  for file in walkDirRec(path):
    if file.endsWith(".txt"):
      checkReferences(file)

echo "Done!"