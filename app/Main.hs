{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

module Main where

import           Control.Exception
import           Data.Binary.Get
import qualified Data.ByteString.Lazy as L
import qualified Data.Map.Strict as M
import           Prana.Decode
import           Prana.Interpret
import           Prana.Types
import           System.Environment

main :: IO ()
main = do
  args <- getArgs
  (indices,binds) <-
    fmap
      (\xs -> (concatMap fst xs, concatMap snd xs))
      (mapM
         (\fp -> do
            bytes <- L.readFile fp
            case runGetOrFail
                   ((,) <$> decodeArray decodeMethodIndex <*>
                    decodeArray decodeBind)
                   bytes of
              Left e ->
                error
                  ("failed to decode " ++
                   fp ++
                   ": " ++ show e ++ ", file contains: " ++ take 10 (show bytes))
              Right (_, _, (indices,binds)) -> do
                pure (indices,binds))
         args)
  let globals =
        M.fromList
          (concatMap
             (\case
                NonRec v e -> [(v, e)]
                Rec bs -> bs)
             binds)
      methods = M.fromList indices
  -- error
  --   ("Methods\n" ++
  --    unlines (map show (M.toList methods)) ++
  --    "\n" ++ "Scope\n" ++ unlines (map show (M.toList globals)))
  case M.lookup "main:Main.main" (M.mapKeys idStableName globals) of
    Nothing -> error "Couldn't find main function."
    Just e ->
      catch
        (runInterpreter globals methods e >>= print)
        (\case
           NotInScope i ->
             error
               ("Not in scope: " ++ show i)
           err -> error (show err))
