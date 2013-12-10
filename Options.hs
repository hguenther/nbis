module Options where

import MemoryModel
import System.Environment (getArgs)
import System.Console.GetOpt
import qualified Data.List as List

data MemoryModelOption = Rivers
                       | Snow
                       deriving (Eq,Ord,Show)

data Options = Options
               { entryPoint :: String
               , bmcDepth :: Integer
               , files :: [String]
               , memoryModelOption :: MemoryModelOption
               , solver :: Maybe String
               , checkErrors :: [ErrorDesc]
               , showHelp :: Bool
               , manualMergeNodes :: Maybe [(String,String,Integer)]
               } deriving (Eq,Ord,Show)

nbisInfo :: String
nbisInfo = usageInfo "USAGE:\n  nbis [OPTION...] FILE [FILE...]\n\nOptions:" optionDescr

defaultOptions :: Options
defaultOptions = Options { entryPoint = "main" 
                         , bmcDepth = 10
                         , files = []
                         , memoryModelOption = Rivers
                         , solver = Nothing
                         , checkErrors = [Custom]
                         , showHelp = False
                         , manualMergeNodes = Nothing }

optionDescr :: [OptDescr (Options -> Options)]
optionDescr = [Option ['e'] ["entry-point"] (ReqArg (\str opt -> opt { entryPoint = str }) "function") "Specify the main function to test"
              ,Option ['d'] ["depth"] (ReqArg (\str opt -> opt { bmcDepth = read str }) "d") "Maximal unroll depth"
              ,Option ['m'] ["memory-model"] (ReqArg (\str opt -> opt { memoryModelOption = case str of
                                                                           "rivers" -> Rivers
                                                                           "snow" -> Snow
                                                                           _ -> error $ "Unknown memory model "++show str
                                                                      }) "model") "Memory model to use (rivers or snow)"
              ,Option [] ["solver"] (ReqArg (\str opt -> opt { solver = Just str }) "smt-binary") "The SMT solver to use to solve the generated instance"
              ,Option [] ["check-errors"] (ReqArg (\str opt -> opt { checkErrors = fmap (\n -> case n of
                                                                                            "user" -> Custom
                                                                                            "null" -> NullDeref
                                                                                            "invalid" -> Overrun
                                                                                            "free-access" -> FreeAccess
                                                                                            "double-free" -> DoubleFree
                                                                                        ) (splitOptions str) }) "opts") "A comma seperated list of bug types which should be checked:\n  user - User defined assertions\n  null - Null pointer dereferentiations\n  invalid - Invalid memory accesses\n  free-access - Access to freed memory locations\n  double-free - Double frees of memory locations"
              ,Option [] ["merge-nodes"] (ReqArg (\str opt -> opt { manualMergeNodes = Just (read str) }) "list") "A list of merge nodes to use"
              ,Option ['h'] ["help"] (NoArg (\opt -> opt { showHelp = True })) "Show this help"
              ]

splitOptions :: String -> [String]
splitOptions "" = []
splitOptions xs = case List.break (==',') xs of
  (x,[]) -> [x]
  (x,',':rest) -> x:splitOptions rest

getOptions :: IO Options
getOptions = do
  args <- getArgs
  let (res,args',errs) = getOpt Permute optionDescr args
  case errs of
    [] -> return $ foldl (.) id res (defaultOptions { files = args' })
    _ -> error $ show errs
