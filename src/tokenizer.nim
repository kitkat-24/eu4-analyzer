import std/[strformat, strutils, sugar, terminal]


type
  TokenKind = enum
    lBrak,
    rBrak
    eq,
    rawStr,
    identifier
  Token* = object
    lex*: string
    line*: int
    col*: int
    kind*: TokenKind

  ExprKind* = enum
    scoped,
    expression,
  Expr* {.acyclic} = ref object
    case kind*: ExprKind
    of scoped:
      name*: string
      children*: seq[Expr]
    of expression:
      left*, right*: string
    line*, col*: int # col is the first character of the expression


proc readEu4*(filename: string): string =
  result = readFile(filename)
  # Strip UTF-8 BOM if present
  if result.startsWith("\xEF\xBB\xBF"):
    result = result[3..^1]

# For a valid token, will get the kind from the first char of the string
func getTokenKind(c: char): TokenKind =
  case c
  of '{': result = lBrak
  of '}': result = rBrak
  of '=': result = eq
  of '"': result = rawStr
  else:   result = identifier

proc tokenize*(content: string): seq[Token] {.gcsafe.} =
  result = newSeqOfCap[Token](content.len div 10)
  var
    i = 0
    line = 1
    col = 1
    lineStart = 0

  while i < content.len:
    let c = content[i]

    case c
    # 1. Handle Whitespace
    of ' ', '\t', '\r':
      inc i
    of '\n':
      inc line
      inc i
      lineStart = i

    # 2. Structural Symbols
    of '{', '}', '=':
      result.add(Token(lex: $c, line: line, col: i - lineStart + 1, kind: getTokenKind(c)))
      inc i

    # 3. Comments
    of '#':
      # Skip until newline
      while i < content.len and content[i] != '\n':
        inc i

    # 4. Strings
    of '"':
      let startIdx = i
      let startCol = i - lineStart + 1
      inc i # skip opening quote
      while i < content.len:
        if content[i] == '\\' and i + 1 < content.len:
          i += 2 # Skip escaped character
        elif content[i] == '"':
          inc i # skip closing quote
          break
        else:
          inc i
      # Add the whole string as one lexeme (lowered if needed)
      result.add(Token(lex: content[startIdx ..< i].toLower(), line: line, col: startCol, kind: rawStr))

    # 5. Words (The "Everything Else" state)
    else:
      let startIdx = i
      let startCol = i - lineStart + 1
      # Continue until we hit whitespace, a symbol, a quote, or a comment
      while i < content.len and not (content[i] in {' ', '\t', '\r', '\n', '{', '}', '=', '#', '"'}):
        inc i

      if startIdx < i:
        result.add(Token(lex: content[startIdx ..< i].toLower(), line: line, col: startCol, kind: identifier))

proc printLineError*(msg, displayPath: string, line, col: int) =
  stdout.styledWriteLine(
    fgRed, styleBright, "Error: ", resetStyle, fgWhite, msg,
    " found at ", displayPath, " at line ", $line, ": ", $col
  )

# Builds the DST (Dumb Syntax Tree) of very simple expression and scope objects
proc buildDST*(tokens: seq[Token], displayPath: string): seq[Expr] {.gcsafe.} =
  # We use a 'dummy' root node to act as the top-level container
  let root = Expr(kind: scoped, name: "ROOT", children: @[])
  var
    stack: seq[Expr] = @[root]
    scopeStart = newSeq[int]()
    i = 0

  while i < tokens.len:
    # It's a scope: name = {
    if i + 2 < tokens.len and tokens[i+1].kind == eq and tokens[i+2].kind == lBrak:
      let newScope = Expr(kind: scoped, name: tokens[i].lex, children: @[], line: tokens[i].line,
                          col: tokens[i].col)
      stack[^1].children.add(newScope) # Add to current active scope
      stack.add(newScope)              # Push object so IT becomes the active scope
      scopeStart.add(i)
      i += 3 # Skip 'name', '=', and '{'
      continue
    # 2. Lookahead for 'key = value'
    if i + 2 < tokens.len and tokens[i+1].kind == eq:
      let e = Expr(kind: expression, left: tokens[i].lex, right: tokens[i+2].lex, line: tokens[i].line,
                   col: tokens[i].col)
      stack[^1].children.add(e)
      i += 3
      continue

    # 2. Handle Closing Scopes
    if tokens[i].kind == rBrak:
      if stack.len > 1:
        discard stack.pop()
        discard scopeStart.pop()
      else:
        printLineError("Extra '}'", displayPath, tokens[i].line, tokens[i].col)
      inc i
      continue

    inc i

  if stack.len > 1:
    let ti = scopeStart[0]
    printLineError("Missing " & $(stack.len-1) & " closing brace(s) '}'", displayPath, tokens[ti].line, tokens[ti].col)
  return stack[0].children # Return the top-level list


# Print a DST for debugging purposes
proc dumpDST*(expressions: seq[Expr], indent = 0) =
  let prefix = "\t".repeat(indent)
  for e in expressions:
    case e.kind
    of expression:
      echo fmt"{prefix}{e.left} = {e.right}"
    of scoped:
      # Difficult to escape the left bracket in a format string without it
      # seeing the next few lines and closing bracket as one big string capture
      echo "$1$2 = {" % [prefix, e.name]
      # Recursively print children with increased indentation
      dumpDST(e.children, indent + 1)
      echo fmt"{prefix}}}"

# --- Test Suite ---

proc runTest() =
  # A "worst case" EU4 script snippet
  let mockFileContent = """
  hidden_effect = {
      set_global_flag = potato_spread # This should be captured
      # This entire line is a comment
      custom_modifier = { name = HUN_fort_defense }
  }
  tag=HUN # Touching symbols
  path = "C:/MyMod#1/test.txt" # Hash inside a string
  """

  echo "--- Raw Input ---"
  echo mockFileContent
  echo "--- Tokenized Output ---"

  let tokens = tokenize(mockFileContent)
  let tokStrs = collect:
    for t in tokens: t.lex

  # Print tokens with brackets to show boundaries clearly
  for i, t in tokStrs:
    stdout.write("[" & t & "] ")
    if (i + 1) mod 5 == 0: echo "" # Wrap every 5 tokens for readability

  echo "\n\n--- Verification ---"

  # Basic assertions to ensure logic is working
  assert "hidden_effect" in tokStrs
  assert "{" in tokStrs
  assert "potato_spread" in tokStrs
  assert "\"C:/MyMod#1/test.txt\"".toLower() in tokStrs
  assert "HUN_fort_defense".toLower() in tokStrs

  # Ensure comments are GONE
  for t in tokStrs:
    if t.contains("#") and not t.startsWith("\""):
      raise newException(ValueError, "Leaked a comment: " & t)

  echo "Success: Tokenizer handled strings, comments, and symbols correctly!"

proc dstTest() =
  let tokens = tokenize(readEu4("test/test_event_file.txt"))
  let dst = buildDST(tokens, "test/test_event_file.txt")
  dumpDST(dst)

if isMainModule:
  # runTest()
  dstTest()