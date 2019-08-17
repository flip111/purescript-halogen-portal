-- | A container component which renders a sub-tree to a DOM node not in the 
-- | tree. This is useful for when a child component needs to 'break out' of a
-- | parent, like dialogs, modals, and tooltips, especially if the parent has
-- | z-indexing or overflow: hidden set.
module Halogen.Portal where

import Prelude
import Control.Coroutine (consumer)
import Control.Monad.Rec.Class (forever)
import Data.Foldable (for_)
import Data.Maybe (Maybe(..), maybe)
import Effect.Aff (Aff, error, forkAff, killFiber)
import Effect.Aff.Bus (BusRW)
import Effect.Aff.Bus as Bus
import Effect.Aff.Class (class MonadAff)
import Halogen as H
import Halogen.Aff (awaitBody)
import Halogen.HTML as HH
import Halogen.Query.EventSource as ES
import Halogen.VDom.Driver as VDom
import Web.HTML (HTMLElement)

type InputRep query input output
  = ( input :: input
    , child :: H.Component HH.HTML query input output Aff
    , targetElement :: Maybe HTMLElement
    )

type Input query input output
  = { | InputRep query input output }

type State query input output
  = { io :: Maybe (H.HalogenIO query output Aff)
    , bus :: Maybe (BusRW output)
    | InputRep query input output
    }

data Action output
  = Initialize
  | HandleOutput output
  | Finalize

component ::
  forall query input output m.
  MonadAff m =>
  H.Component HH.HTML query (Input query input output) output m
component =
  H.mkComponent
    { initialState
    , render
    , eval:
      H.mkEval
        $ H.defaultEval
            { initialize = Just Initialize
            , handleAction = handleAction
            , finalize = Just Finalize
            }
    }
  where
  initialState :: Input query input output -> State query input output
  initialState { input, child, targetElement } =
    { input
    , child
    , targetElement
    , io: Nothing
    , bus: Nothing
    }

  handleAction :: Action output -> H.HalogenM (State query input output) (Action output) () output m Unit
  handleAction = case _ of
    Initialize -> do
      state <- H.get
      -- The target element can either be the one supplied by the user, or the 
      -- document body. Either way, we'll run the sub-tree at the target and 
      -- save the resulting interface.
      target <- maybe (H.liftAff awaitBody) pure state.targetElement
      io <- H.liftAff $ VDom.runUI state.child state.input target
      H.modify_ _ { io = Just io }
      -- Subscribe to a new event bus, which will run each time a new output
      -- is emitted by the child component.
      _ <- H.subscribe <<< map HandleOutput <<< busEventSource =<< H.liftEffect Bus.make
      -- Subscribe to the child component, writing to the bus every time a 
      -- message arises. This indirection through the bus is necessary because 
      -- the component is being run via Aff, not HalogenM
      H.liftAff $ io.subscribe
        $ consumer \msg -> do
            for_ state.bus (Bus.write msg)
            pure Nothing
    -- This action is called each time the child component emits a message
    HandleOutput output -> H.raise output
    Finalize -> do
      state <- H.get
      for_ state.io (H.liftAff <<< _.dispose)

  -- We don't need to render anything; this component is explicitly meant to be 
  -- passed through.
  render :: State query input output -> H.ComponentHTML (Action output) () m
  render _ = HH.text ""

-- Create an event source from a many-to-many bus, which a Halogen component 
-- can subscribe to.
busEventSource :: forall m r act. MonadAff m => Bus.BusR' r act -> ES.EventSource m act
busEventSource bus =
  ES.affEventSource \emitter -> do
    fiber <- forkAff $ forever $ ES.emit emitter =<< Bus.read bus
    pure (ES.Finalizer (killFiber (error "Event source closed") fiber))
