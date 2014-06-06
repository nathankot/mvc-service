{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeFamilies #-}

module MVC.Model.Pure where

import           Control.Applicative
import           Control.Monad
import           Control.Monad.Reader             (MonadReader (..))
import           Control.Monad.State              (MonadState (..))
import           Control.Monad.Trans.Reader       (ReaderT)
import qualified Control.Monad.Trans.Reader       as R
import           Control.Monad.Trans.State.Strict (State, StateT)
import qualified Control.Monad.Trans.State.Strict as S
import           Data.Monoid
import           Data.Traversable                 (traverse)
import           Lens.Family                      (LensLike',set)
import           Lens.Family.State.Strict         (zoom)
import           Pipes

import           MVC.Event                        (EitherSomeEvent,Event,SomeEvent(..))

-----------------------------------------------------------------------------

type ModelP a b s = Pipe a b (State s) 

newtype EventHandlerP a b s r = 
  EventHandlerP (StateT (EventHandler a b s) (ModelP a b s) r) 
  deriving (Functor,Applicative,Monad,MonadState [SomeEventHandler a b s])

newtype SomeEventHandlerP a b s r = 
  SomeEventHandlerP (StateT (SomeEventHandler a b s) (ModelP a b s) r) 
  deriving (Functor,Applicative,Monad,MonadState (SomeEventHandler a b s))

newtype HandleEvent v r = 
  HandleEvent (ReaderT (Int,AppStateAPI v) (StateT v (State (AppState v))) r) 
  deriving (Functor,Applicative,Monad,MonadReader (Int,AppStateAPI v))

type HandleEventResult a b v = HandleEvent v [Either a b]

class HandlesEvent a where
  type AppState a :: *
  type EventIn a :: *
  type EventOut a :: *
  data AppStateAPI a :: *
  handleEvent :: a -> EventIn a -> HandleEventResult (EventIn a) (EventOut a) a

data SomeEventHandler :: * -> * -> * -> * where
  SomeEventHandler :: (HandlesEvent v, AppState v ~ s, EventIn v ~ a, EventOut v ~ b) => 
    { _ehId :: Int
    , _ehAPI :: AppStateAPI v
    , _ehEventIn :: a' -> Maybe a
    , _ehEventOut :: Either a b -> Either a' b'
    , _ehEventHandler :: v
    } -> SomeEventHandler a' b' s

ehId :: Functor f => LensLike' f (SomeEventHandler a b v) Int
ehId f (SomeEventHandler i a ein eout s) = (\i' -> SomeEventHandler i' a ein eout s) <$> f i

newtype EventHandler a b s = 
  EventHandler { _eventHandlers :: [SomeEventHandler a b s] }
  deriving (Monoid)

eventHandlers :: Functor f => LensLike' f (EventHandler a b s) Int
eventHandlers f (EventHandler h) = (\h' -> EventHandler h') <$> f i

initialiseEventHandler :: EventHandler a b s -> EventHandler a b s
initialiseEventHandler = over eventHandlers (zipWith (set ehId) [1..])

-----------------------------------------------------------------------------

runRecursiveEventHandler :: EventHandler a b s -> ModelP a b s r
runRecursiveEventHandler = flip runEventHandlerP recursiveEventHandlerP

runEventHandlerP :: EventHandler a b s -> EventHandlerP a b s r -> ModelP a b s r
runEventHandlerP eventhandler (EventHandlerP eventHandlerP) = S.evalStateT eventHandlerP eventHandler 

recursiveEventHandlerP :: EventHandlerP a b s ()
recursiveEventHandlerP = forever $ EventHandlerP (lift await) >>= go
  where 
  go e = do
    r <- forEventHandlers $ do
      eventHandler <- getEventHandlerP
      appState <- getAppStateP 
      let (r,appSvc',appState') = runEventHandler eventHandler appState e  
      putEventHandlerP appSvc'
      putAppStateP appState'
      return r
    mapM_ (either go releaseP) r

runEventHandler :: SomeEventHandler a b s -> a -> b -> ([Either b c],SomeEventHandler a b s,a)
runEventHandler eventHandler@SomeEventHandler{..} appstate event = 
  maybe ignore process (_ehEventIn event)
  where 
  ignore = ([],eventHandler,appstate)
  process event' = 
    let
      (HandleEvent handleEvent) = processEvent _ehEventHandler event'
      ((events,eventHandler'),appstate') = S.runState (S.runStateT (R.runReaderT handleEvent (_ehId,_ehAPI)) _ehEventHandler) appstate
    in 
      (map _ehEventOut events,(SomeEventHandler _ehId _ehAPI _ehEventIn _ehEventOut eventHandler'),appstate')

-----------------------------------------------------------------------------

forEventHandlers :: (Monoid r) => SomeEventHandlerP a b s r -> EventHandlerP a b s r
forEventHandlers (AppModel' am') = EventHandlerP $ zoom (eventHandlers . traverse) am'

releaseP :: c -> EventHandlerP a b s ()
releaseP = EventHandlerP . lift . yield

getEventHandlerP :: SomeEventHandlerP a b s (SomeEventHandler a b s)
getEventHandlerP = SomeEventHandlerP S.get

putEventHandlerP :: SomeEventHandler a b s -> SomeEventHandlerP a b s ()
putEventHandlerP = SomeEventHandlerP . S.put

getAppStateP :: SomeEventHandlerP a b s a
getAppStateM = SomeEventHandlerP $ lift $ lift S.get

putAppStateP :: a -> SomeEventHandlerP a b s ()
putAppStateM = SomeEventHandlerP . lift . lift . S.put

-----------------------------------------------------------------------------

getEventHandlerId :: HandleEvent a Int
getEventHandlerId = HandleEvent (R.asks fst)

getAppStateAPI :: HandleEvent a (AppStateAPI a)
getAppStateAPI = HandleEvent (R.asks snd)

getEventHandler :: HandlesEvent a => HandleEvent a a
getEventHandler = HandleEvent $ lift $ S.get

putEventHandler :: HandlesEvent a => a -> HandleEvent a ()
putEventHandler = HandleEvent . lift . S.put 

getAppState :: HandleEvent a (AppState a)
getAppState = HandleEvent $ lift $ lift $ S.get

putAppState :: AppState a -> HandleEvent a ()
putAppState = HandleEvent . lift . lift . S.put

getsAppState :: (AppState a -> r) -> HandleEvent a r
getsAppState f = liftM f getAppState 

modifyAppState :: (AppState a -> AppState a) -> HandleEvent a ()
modifyAppState = HandleEvent . lift . lift . S.modify

modifyAppState' :: (AppState a -> (r,AppState a)) -> HandleEvent a r
modifyAppState' f = do
  s <- getAppState
  let (r,s') = f s
  putAppState s'
  return r

modifyAppState'' :: (AppState a -> Maybe (r,AppState a)) -> HandleEvent a (Maybe r)
modifyAppState'' f = do
  s <- getAppState
  maybe (return Nothing) (\(r,s') -> putAppState s' >> return (Just r)) (f s)

withAppState :: (AppState a -> HandleEvent a r) -> HandleEvent a r
withAppState f = getAppState >>= f

noEvents :: HandleEvent a [b] 
noEvents = return []

propagate :: b -> Either b c
propagate = Left 

propagateEvent :: Event b => b -> EitherSomeEvent
propagateEvent = propagate . SomeEvent 

release :: c -> Either b c
release = Right

releaseEvent :: Event c => c -> EitherSomeEvent
releaseEvent = release . SomeEvent 

