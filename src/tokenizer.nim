import std/[nre, strutils, sugar]


type
  Token* = object
    lex*: string
    line*: int
    col*: int


proc readEu4*(filename: string): string =
  result = readFile(filename)
  # Strip UTF-8 BOM if present
  if result.startsWith("\xEF\xBB\xBF"):
    result = result[3..^1]

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
      result.add(Token(lex: $c, line: line, col: i - lineStart + 1))
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
      result.add(Token(lex: content[startIdx ..< i].toLower(), line: line, col: startCol))

    # 5. Words (The "Everything Else" state)
    else:
      let startIdx = i
      let startCol = i - lineStart + 1
      # Continue until we hit whitespace, a symbol, a quote, or a comment
      while i < content.len and not (content[i] in {' ', '\t', '\r', '\n', '{', '}', '=', '#', '"'}):
        inc i

      if startIdx < i:
        result.add(Token(lex: content[startIdx ..< i].toLower(), line: line, col: startCol))

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

if isMainModule:
  runTest()