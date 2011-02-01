{-# LANGUAGE RecordWildCards #-}

module Web.Server(server) where

import General.Base
import General.Web
import CmdLine.All
import Web.Response
import Web.Page
import System.IO.Unsafe(unsafeInterleaveIO)
import Control.Monad.IO.Class
import General.System
import Control.Concurrent
import System.Time

import Network.Wai
import Network.Wai.Handler.Warp
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.ByteString.Char8 as BS


server :: CmdLine -> IO ()
server q@Server{..} = do
    resp <- respArgs q
    v <- newMVar ()
    putStrLn $ "Starting Hoogle Server on port " ++ show port
    let err x = putStrLn $ "Error: " ++ show x
    runEx err port $ \r -> liftIO $ do
        withMVar v $ const $ putStrLn $ bsUnpack (pathInfo r) ++ bsUnpack (queryString r)
        talk resp q r


respArgs :: CmdLine -> IO (IO ResponseArgs)
respArgs Server{..} = do
    t <- getTemplate
    if dynamic
        then return $ args t
        else do x <- args t; return $ return x
    where
        getTemplate
            | null template = return $ return defaultTemplates
            | otherwise = do
                let get = fmap (loadTemplates . unlines) $ mapM readFile template
                if dynamic then  buffer template get else return get

        modTime ext = unsafeInterleaveIO $ do
            TOD a _ <- getModificationTime $ resources </> "hoogle" <.> ext
            return $ show a

        args t = do
            css <- modTime "css"; js <- modTime "js"
            t <- t
            return $ responseArgs{updatedCss=css, updatedJs=js, templates=t}


-- | Given a set of paths something relies on, and a value to generate it, return something that generates it minimally
buffer :: [FilePath] -> IO a -> IO (IO a)
buffer files act = do
    val <- act
    ts <- mapM getModificationTime files
    ref <- newMVar (ts,val)
    return $ modifyMVar ref $ \(ts,val) -> do
        ts2 <- mapM getModificationTime files
        if ts == ts2 then return ((ts,val),val) else do
            val <- act
            return ((ts2,val),val)


-- FIXME: Avoid all the conversions to/from LBS
talk :: IO ResponseArgs -> CmdLine -> Request -> IO Response
talk resp Server{..} Request{pathInfo=path_, queryString=query_}
    | path `elem` ["/","/hoogle"] = do
        let args = parseHttpQueryArgs $ drop 1 query
        cmd <- cmdLineWeb args
        resp <- resp
        r <- response resp cmd{databases=databases}
        if local_ then rewriteFileLinks r else return r
    | takeDirectory path == "/res" = serveFile True $ resources </> takeFileName path
    | local_ && "/file/" `isPrefixOf` path = serveFile False $ drop 6 path
    | otherwise = return $ responseNotFound $ show path
    where (path,query) = (bsUnpack path_, bsUnpack query_)


serveFile :: Bool -> FilePath -> IO Response
serveFile cache file = do
    b <- doesFileExist file
    return $ if not b
        then responseNotFound file
        else ResponseFile statusOK hdr file
    where hdr = [(hdrContentType, fromString $ contentExt $ takeExtension file)] ++
                [(hdrCacheControl, fromString "max-age=604800" {- 1 week -}) | cache]


rewriteFileLinks :: Response -> IO Response
rewriteFileLinks r = do
    (a,b,c) <- responseFlatten r
    let res = LBS.fromChunks $ f $ BS.concat $ LBS.toChunks c
    return $ responseLBS a b res
    where
        f x | BS.null b = [a]
            | otherwise = a : rep : f (BS.drop nfind b) 
            where (a,b) = BS.breakSubstring find x

        find = fromString "href='file://"
        rep = fromString "href='/file/"
        nfind = BS.length find


contentExt ".png" = "image/png"
contentExt ".css" = "text/css"
contentExt ".js" = "text/javascript"
contentExt ".html" = "text/html"
contentExt ".htm" = "text/html"
contentExt _ = "text/plain"
