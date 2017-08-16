{-# LANGUAGE NoImplicitPrelude, GeneralizedNewtypeDeriving #-}
{-|
Module : Yarn.Lock.Parse
Description : Parser for yarn.lock files
Maintainer : Profpatsch
Stability : experimental

This module provides a parser for the AST of @yarn.lock@ files.
-}
module Yarn.Lock.Parse
( PackageFields(..), Package
-- , Yarn.Lock.parse
-- | = Parsers
-- , lockfile, packageListToLockfile
, packageList
, packageEntry
-- re-export
, Parser
-- = internal parsers
, field, packageKeys, packageKey
) where

import Protolude hiding (try)
import qualified Data.Char as Ch
import qualified Data.Text as Text
import qualified Data.Map.Strict as M
import Text.Megaparsec as MP hiding (space)
import Text.Megaparsec.Text
import qualified Text.Megaparsec.Lexer as MPL
import qualified Data.Text as Text

-- import qualified Data.MultiKeyedMap as MKM
-- import Data.Proxy (Proxy(..))

import qualified Yarn.Lock.Types as T


-- | The @yarn.lock@ format doesn’t specifically include a fixed scheme,
-- it’s just an unnecessary custom version of a list of fields.
--
-- An field can either be a string or more fields w/ deeper indentation.
--
-- The actual conversion to semantic structures needs to be done afterwards.
newtype PackageFields = PackageFields (Map Text (Either Text PackageFields))
  deriving (Show, Eq, Monoid)
type Package = T.Keyed (SourcePos, PackageFields)


-- | Parse a complete yarn.lock into an abstract syntax tree,
-- keeping the source positions of each package entry.
packageList :: Parser [Package]
packageList = many $ (skipMany (comment <|> eol)) *> packageEntry
                where comment = char '#' *> manyTill anyChar eol

-- | A single Package.
--
-- Example:
--
-- @
-- handlebars@^4.0.4:
--   version "4.0.6"
--   resolved "https://registry.yarnpkg.com/handlebars/-/handlebars-4.0.6.tgz#2ce4484850537f9c97a8026d5399b935c4ed4ed7"
--   dependencies:
--     async "^1.4.0"
--     optimist "^0.6.1"
--     source-map "^0.4.4"
--   optionalDependencies:
--     uglify-js "^2.6"
-- @
packageEntry :: Parser (T.Keyed (SourcePos, PackageFields))
packageEntry = label "package entry" $ do
  pos <- getPosition
  -- A package entry is a non-indented
  (keys, pkgs) <- nonIndented
            -- block that has a header of package keys
            -- and an indented part that contains fields
            $ indentedFieldsWithHeader packageKeys
  pure $ T.Keyed keys (pos, pkgs)

-- | The list of PackageKeys that index the same Package
--
-- @
-- align-text@^0.1.1, align-text@^0.1.3:\\n
-- @
packageKeys :: Parser [T.PackageKey]
packageKeys = label "package keys" $ do
  firstEls <- many (try $ lexeme $ packageKey ":," <* char ',')
  lastEl   <-                      packageKey ":"  <* char ':'
  pure $ firstEls ++ [lastEl]

-- | A packageKey is @\<package-name\>\@\<semver\>@;
--
-- If the semver contains spaces, it is also quoted with @"@.
packageKey :: [Char] -> Parser T.PackageKey
packageKey separators = inString (pkgKey "\"")
         -- if no string delimiters is used we need to check for the separators
         -- this file format is shit :<
         <|> pkgKey separators
         <?> "package key"
  where
    pkgKey valueChars = do
      pkgName <- someTextOf (noneOf "@") <?> "package name part of package key"
      _ <- char '@'
      semver <- (someTextOf (noneOf valueChars))
                <|> (pure Text.empty <?> "an empty semver")
                <?> "semver part of package key"
      pure $ T.PackageKey pkgName semver


-- | Either a simple or a nested field.
field :: Parser (Text, Either Text PackageFields)
field = try nested <|> simple <?> "field"
  where
    simple = fmap Left <$> simpleField
    nested = fmap Right <$> nestedField

-- | A key-value pair, separated by space. The value is enclosed in "".
-- Returns key and value.
simpleField :: Parser (Text, Text)
simpleField = (,) <$> lexeme symbolChars
                  -- valueChars may be in Strings or maybe not >:
                  -- this file format is absolute garbage
                  <*> (strValueChars <|> valueChars)
                  <?> "simple field"
  where
    valueChars, strValueChars :: Parser Text
    valueChars = someTextOf (noneOf "\n\r\"")
    strValueChars = inString $ valueChars
      -- as with packageKey semvers, this can be empty
      <|> (pure Text.empty <?> "an empty value field")

-- | Similar to a 'simpleField', but instead of a string
-- we get another block with deeper indentation.
nestedField :: Parser (Text, PackageFields)
nestedField = label "nested field" $
  indentedFieldsWithHeader (symbolChars <* char ':')


-- internal parsers

-- | There are two kinds of indented blocks:
-- One where the header is the package
-- and one where the header is already a package field key.
indentedFieldsWithHeader :: Parser a -> Parser (a, PackageFields)
indentedFieldsWithHeader header = indentBlock $ do
    -- … block that has a header of package keys
    hdr <- header
    -- … and an indented part that contains fields
    pure $ MPL.IndentSome Nothing
      (\fields -> pure (hdr, toPfs fields)) field
  where
    toPfs :: [(Text, Either Text PackageFields)] -> PackageFields
    toPfs = PackageFields . M.fromList

-- | Characters allowed in key symbols.
-- 
-- TODO: those are partly npm package names, so check the allowed symbols, too.
--
-- Update: npm doesn’t specify the package name format, at all.
-- Apart from the length.
symbolChars :: Parser Text
symbolChars = label "key symbol" $ someTextOf $ satisfy
  (\c -> Ch.isAscii c &&
     (Ch.isLower c || Ch.isUpper c || Ch.isNumber c || c `elem` "-_."))


-- text versions of parsers & helpers

someTextOf :: Parser Char -> Parser Text
someTextOf c = Text.pack <$> some c

-- | parse everything as inside a string
inString :: Parser a -> Parser a
inString = between (char '"') (char '"')

-- lexers

-- | Parse whitespace.
space :: Parser ()
space = MPL.space (void MP.spaceChar)
                  (MPL.skipLineComment "# ")
                  (void $ satisfy (const False))

-- | Parse a lexeme.
lexeme :: Parser a -> Parser a
lexeme = MPL.lexeme space

-- | Ensure parser is not indented.
nonIndented :: Parser a -> Parser a
nonIndented = MPL.nonIndented space
indentBlock = MPL.indentBlock space
