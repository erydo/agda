
module Agda.Syntax.Parser
    ( -- * Types
      Parser
      -- * Parse functions
    , Agda.Syntax.Parser.parse
    , Agda.Syntax.Parser.parseLiterate
    , Agda.Syntax.Parser.parsePosString
    , parseFile'
      -- * Parsers
    , moduleParser
    , exprParser
    , tokensParser
      -- * Parse errors
    , ParseError(..)
    ) where

import Control.Exception
import Data.List

import Agda.Syntax.Position
import Agda.Syntax.Parser.Monad as M hiding (Parser, parseFlags)
import qualified Agda.Syntax.Parser.Monad as M
import qualified Agda.Syntax.Parser.Parser as P
import Agda.Syntax.Parser.Lexer
import Agda.Syntax.Concrete
import Agda.Syntax.Parser.Tokens

import Agda.Utils.FileName

------------------------------------------------------------------------
-- Wrapping parse results

wrap :: ParseResult a -> a
wrap (ParseOk _ x)	= x
wrap (ParseFailed err)	= throw err

wrapM:: Monad m => m (ParseResult a) -> m a
wrapM m =
    do	r <- m
	case r of
	    ParseOk _ x	    -> return x
	    ParseFailed err -> throw err

------------------------------------------------------------------------
-- Parse functions

-- | Wrapped Parser type.

data Parser a = Parser
  { parser     :: M.Parser a
  , parseFlags :: ParseFlags
  }

parse :: Parser a -> String -> IO a
parse p = wrapM . return . M.parse (parseFlags p) [normal] (parser p)

parseFile :: Parser a -> FileIdAndPath -> IO a
parseFile p = wrapM . M.parseFile (parseFlags p) [layout, normal] (parser p)

parseLiterate :: Parser a -> String -> IO a
parseLiterate p =
  wrapM . return . M.parse (parseFlags p) [literate, layout, code] (parser p)

parseLiterateFile :: Parser a -> FileIdAndPath -> IO a
parseLiterateFile p =
  wrapM . M.parseFile (parseFlags p) [literate, layout, code] (parser p)

parsePosString :: Parser a -> Position -> String -> IO a
parsePosString p pos =
  wrapM . return . M.parsePosString pos (parseFlags p) [normal] (parser p)

parseFile' :: Parser a -> FileIdAndPath -> IO a
parseFile' p (id, file) =
  if "lagda" `isSuffixOf` filePath file then
    Agda.Syntax.Parser.parseLiterateFile p (id, file)
   else
    Agda.Syntax.Parser.parseFile p (id, file)

------------------------------------------------------------------------
-- Specific parsers

-- | Parses a module.

moduleParser :: Parser Module
moduleParser = Parser { parser = P.moduleParser
                      , parseFlags = withoutComments }

-- | Parses an expression.

exprParser :: Parser Expr
exprParser = Parser { parser = P.exprParser
                    , parseFlags = withoutComments }

-- | Gives the parsed token stream (including comments).

tokensParser :: Parser [Token]
tokensParser = Parser { parser = P.tokensParser
                      , parseFlags = withComments }

-- | Keep comments in the token stream generated by the lexer.

withComments :: ParseFlags
withComments = defaultParseFlags { parseKeepComments = True }

-- | Do not keep comments in the token stream generated by the lexer.

withoutComments :: ParseFlags
withoutComments = defaultParseFlags { parseKeepComments = False }
