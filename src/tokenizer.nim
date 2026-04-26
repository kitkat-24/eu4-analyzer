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

# The Regex Pattern:
# 1. "(?:\\.|[^"\\])*"  -> Matches double-quoted strings (handling escapes)
# 2. \{|\}|=|           -> Matches structural symbols: { } =
# 3. [^\s\{\}#=]+         -> Matches "words" (anything not whitespace/symbol/hash)
# 4. #.* -> Matches comments from # to end of line
# r"..." is a raw literal string, which allows specifying a quotatio mark as
# part of the string with "". We can't start it with """ though because that
# parses as the start of a multiline string, so we break it up by wrapping the
# string capture pattern in ()
proc tokenize*(content: string): seq[Token] {.gcsafe.} =
  ## Breaks EU4 script content into a stream of meaningful tokens.
  ## Handles strings, structural symbols, and strips comments.
  var
    lineNum = 1
    offset = 0
    lastLineStart = 0
  let pattern = re(r"(""(?:\\.|[^""\\])*"")|\{|\}|=|[^\s\{\}#=]+|#.*")

  for line in splitLines(content):
    for m in line.findIter(pattern):
      # for i in offset ..< m.matchBounds.a:
      #   if content[i] == '\n':
      #     inc lineNum
      #     lastLineStart = i + 1

      let col = m.matchBounds.a - lastLineStart + 1
      offset = m.matchBounds.b

      # If the token starts with #, it is a comment. We discard it.
      if m.match.startsWith("#"):
        continue

      result.add(Token(lex: m.match.toLower(), line: lineNum, col: col))
      inc lineNum

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
  assert "\"C:/MyMod#1/test.txt\"" in tokStrs
  assert "HUN_fort_defense" in tokStrs

  # Ensure comments are GONE
  for t in tokStrs:
    if t.contains("#") and not t.startsWith("\""):
      raise newException(ValueError, "Leaked a comment: " & t)

  echo "Success: Tokenizer handled strings, comments, and symbols correctly!"

if isMainModule:
  runTest()