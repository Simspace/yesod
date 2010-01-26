-- | The basic typeclass for a Yesod application.
module Yesod.Yesod
    ( Yesod (..)
    , YesodApproot (..)
    , getApproot
    , toHackApp
    ) where

import Data.Object.Html
import Yesod.Response
import Yesod.Request
import Yesod.Definitions
import Yesod.Handler
import Yesod.Template (TemplateGroup)

import Data.Maybe (fromMaybe)
import Text.StringTemplate
import Web.Mime
import Web.Encodings (parseHttpAccept)

import qualified Hack
import Hack.Middleware.CleanPath
import Hack.Middleware.ClientSession
import Hack.Middleware.Gzip
import Hack.Middleware.Jsonp
import Hack.Middleware.MethodOverride

class Yesod a where
    -- | Please use the Quasi-Quoter, you\'ll be happier. For more information,
    -- see the examples/fact.lhs sample.
    handlers :: Resource -> Verb -> Handler a ChooseRep

    -- | The encryption key to be used for encrypting client sessions.
    encryptKey :: a -> IO Word256
    encryptKey _ = getKey defaultKeyFile

    -- | Number of minutes before a client session times out. Defaults to
    -- 120 (2 hours).
    clientSessionDuration :: a -> Int
    clientSessionDuration = const 120

    -- | Output error response pages.
    errorHandler :: ErrorResponse -> Handler a ChooseRep
    errorHandler = defaultErrorHandler

    -- | The template directory. Blank means no templates.
    templateDir :: a -> FilePath
    templateDir _ = ""

class Yesod a => YesodApproot a where
    -- | An absolute URL to the root of the application.
    approot :: a -> Approot

getApproot :: YesodApproot y => Handler y Approot
getApproot = approot `fmap` getYesod

justTitle :: String -> HtmlObject
justTitle = cs . Tag "title" [] . cs

defaultErrorHandler :: Yesod y
                    => ErrorResponse
                    -> Handler y ChooseRep
defaultErrorHandler NotFound = do
    rr <- getRawRequest
    return $ chooseRep
        ( justTitle "Not Found"
        , toHtmlObject [("Not found", show rr)]
        )
defaultErrorHandler PermissionDenied =
    return $ chooseRep
        ( justTitle "Permission Denied"
        , toHtmlObject "Permission denied"
        )
defaultErrorHandler (InvalidArgs ia) =
    return $ chooseRep (justTitle "Invalid Arguments", toHtmlObject
            [ ("errorMsg", toHtmlObject "Invalid arguments")
            , ("messages", toHtmlObject ia)
            ])
defaultErrorHandler (InternalError e) =
    return $ chooseRep (justTitle "Internal Server Error", toHtmlObject
                [ ("Internal server error", e)
                ])

toHackApp :: Yesod y => y -> IO Hack.Application
toHackApp a = do
    key <- encryptKey a
    app' <- toHackApp' a
    let mins = clientSessionDuration a
    return $ gzip
           $ cleanPath
           $ jsonp
           $ methodOverride
           $ clientsession encryptedCookies key mins
           $ app'

toHackApp' :: Yesod y => y -> IO Hack.Application
toHackApp' y = do
    let td = templateDir y
    tg <- if null td
            then return nullGroup
            else directoryGroupRecursiveLazy td
    return $ toHackApp'' y tg

toHackApp'' :: Yesod y => y -> TemplateGroup -> Hack.Env -> IO Hack.Response
toHackApp'' y tg env = do
    let (Right resource) = splitPath $ Hack.pathInfo env
        types = httpAccept env
        verb = cs $ Hack.requestMethod env
        handler = handlers resource verb
        rr = cs env
    res <- runHandler handler errorHandler rr y tg types
    responseToHackResponse res

httpAccept :: Hack.Env -> [ContentType]
httpAccept = map TypeOther . parseHttpAccept . fromMaybe ""
           . lookup "Accept" . Hack.http
