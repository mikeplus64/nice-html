{-# LANGUAGE DeriveFoldable             #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE DeriveTraversable          #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedLabels           #-}
{-# LANGUAGE OverloadedLists            #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE Rank2Types                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
module Text.Html.Nice
  ( -- * Markup DSL
    Attr (..)
  , Markup' (..)
  , IsEscaped (..)
    -- * Compilation
  , compile_
    -- * Rendering
    -- ** Rendering through some monad
  , renderM
  , renderMs
  , Identity (..)
    -- ** Pure rendering
  , render
  , Render (..)
    -- * Util
  , TLB.toLazyText
    -- * Internals
  , SomeText (..)
  , Stream (..)
  , Next (..)
  , Markup'F (..)
  , FastMarkup (..)
  , (:$)(..)
  , plateFM
  ) where
import           Control.Monad
import           Control.Monad.Free
import           Control.Monad.Free.Church
import           Control.Monad.ST.Strict
import           Control.Monad.Trans.Reader
import           Control.Monad.Trans.State.Strict
import           Data.Bifunctor
import           Data.Bifunctor.TH
import           Data.Coerce
import           Data.Functor.Foldable
import           Data.Functor.Foldable.TH
import           Data.Functor.Identity
import           Data.Monoid
import           Data.STRef
import           Data.String
import           Data.Text                        (Text)
import qualified Data.Text                        as T
import qualified Data.Text.Lazy                   as TL
import qualified Data.Text.Lazy.Builder           as TLB
import           Data.Vector                      (Vector)
import qualified Data.Vector                      as V
import           Data.Void
import           GHC.OverloadedLabels             (IsLabel (..))
import           GHC.TypeLits                     (KnownSymbol, symbolVal')
import qualified Text.Blaze                       as Blaze
import qualified Text.Blaze.Internal              as Blaze (textBuilder)
import qualified Text.Blaze.Renderer.Text         as Blaze

import           Debug.Trace

type AttrName = Text

data Attr a = (:=)
  { attrKey :: !AttrName
  , attrVal :: !Text
  } | (:-)
  { attrKey     :: !AttrName
  , attrValHole :: a
  } deriving (Show, Eq, Functor, Foldable, Traversable)

data IsEscaped = DoEscape | Don'tEscape
  deriving (Show, Eq)

data SomeText
  = LazyT TL.Text
  | BuilderT TLB.Builder
  | StrictT !T.Text
  deriving (Show, Eq)

-- | A very simple HTML DSL
data Markup' a
  = Doctype
  | Node !Text !(Vector (Attr a)) (Markup' a)
  | List [Markup' a]
  | Stream (Stream a)
  | Text !IsEscaped !SomeText
  | Hole !IsEscaped a
  | Empty
  deriving (Show, Eq, Functor, Foldable, Traversable)

data Stream a
  = forall s t. S !s !(s -> Next s t) !(t -> FastMarkup a)
  | forall s. ListS [s] (s -> FastMarkup a)

instance Show (Stream a) where
  show _ = "Stream"

-- | Don't use this! It's a lie!
instance Eq (Stream a) where
  _ == _ = True

instance Functor Stream where
  fmap f (S s next fm) = S s next (\s' -> fmap f (fm s'))
  fmap f (ListS l g) = ListS l (\s -> fmap f (g s))

instance Foldable Stream where
  foldMap f (S s0 next fm) = go s0
    where
      go s = case next s of
        Next s1 a -> foldMap f (fm a) <> go s1
        Done a    -> foldMap f (fm a)
  foldMap f (ListS s fm) = foldMap (foldMap f . fm) s

data List1 a = Cons1 a (List1 a) | Nil1 a
  deriving (Functor, Foldable, Traversable)

unstream :: (FastMarkup a -> b) -> Stream a -> (b -> c -> c) -> c -> c
unstream f (S s0 next fm) cons nil = go s0
  where
    go s = case next s of
      Next s1 a -> cons (f (fm a)) (go s1)
      Done a    -> cons (f (fm a)) nil
unstream f (ListS l fm) cons nil = go l
  where
    go (x:xs) = cons (f (fm x)) (go xs)
    go []     = nil

instance Traversable Stream where
  -- phew ...
  traverse f str =
    (\s0' -> ListS s0' id) <$>
    sequenceA (unstream (traverse f) str (:) [])

data Next s a
  = Next !s !a
  | Done !a
  deriving (Show, Eq, Functor, Foldable, Traversable)

--------------------------------------------------------------------------------
-- Compiling

data a :$ b = (:$) (FastMarkup (a -> b)) a
  deriving (Functor)

infixl 0 :$

instance Show a => Show (a :$ b) where
  show (a :$ b) = '(':showsPrec 11 b (' ':':':'$':' ':showsPrec 11 (b <$ a) ")")

data FastMarkup a
  = Bunch {-# UNPACK #-} !(Vector (FastMarkup a))
  | FStream (Stream a)
  | FLText TL.Text
  | FSText {-# UNPACK #-} !Text
  | FBuilder !TLB.Builder
  | FHole !IsEscaped !a
  | FEmpty
  deriving (Show, Eq, Functor, Foldable, Traversable)

instance Monoid (FastMarkup a) where
  mempty = FBuilder mempty
  mappend a b = Bunch [a, b]

makeBaseFunctor ''Markup'
deriveBifunctor ''Markup'F

{-# INLINE plateFM #-}
-- | Unlike 'plate', this uses 'Monad'. That's because 'traverse' over 'Vector'
-- is really quite slow.
plateFM :: Monad m
        => (FastMarkup a -> m (FastMarkup a))
        -> FastMarkup a
        -> m (FastMarkup a)
plateFM f x = case x of
  Bunch v -> Bunch <$> V.mapM f v
  _       -> pure x

compileAttrs :: forall a. Vector (Attr a) -> (TLB.Builder, Vector (Attr a))
compileAttrs v = (static, dynAttrs)
  where
    isHoly :: Foldable f => f a -> Bool
    isHoly = foldr (\_ _ -> True) False

    staticAttrs :: Vector (Attr {- Void -} a)
    dynAttrs :: Vector (Attr a)
    (dynAttrs, staticAttrs) = case V.unstablePartition isHoly v of
      (dyn, stat) -> (dyn, {- unsafeCoerce -} stat)

    static :: TLB.Builder
    static =
      V.foldr
      (\((:=) key val) xs ->
         " " <> TLB.fromText key <> "=\"" <> escapeText val <> "\"" <> xs)
      mempty
      staticAttrs

escapeText :: Text -> TLB.Builder
escapeText = Blaze.renderMarkupBuilder . Blaze.text

{-# INLINE escape #-}
escape :: SomeText -> TLB.Builder
escape st = case st of
  StrictT t  -> Blaze.renderMarkupBuilder (Blaze.text t)
  LazyT t    -> Blaze.renderMarkupBuilder (Blaze.lazyText t)
  BuilderT t -> Blaze.renderMarkupBuilder (Blaze.textBuilder t)

toText :: TLB.Builder -> Text
toText = TL.toStrict . TLB.toLazyText

fastAttr :: Attr a -> FastMarkup a
fastAttr ((:-) k v) =
  Bunch [FSText (" " <> k <> "=\""), FHole DoEscape v, FSText "\""]
fastAttr _ =
  error "very bad"

fast :: Markup' a -> FastMarkup a
fast m = case m of
  Doctype -> FSText "<!DOCTYPE html>\n"
  Node t attrs m' -> case compileAttrs attrs of
    (staticAttrs, dynAttrs) -> case V.length dynAttrs of
      0 -> Bunch
        [ FSText (T.concat ["<", t, toText staticAttrs, ">"])
        , fast m'
        , FSText (T.concat ["</", t, ">"])
        ]
      _ -> Bunch
        [ FBuilder ("<" <> TLB.fromText t <> staticAttrs)
        , Bunch (V.map fastAttr dynAttrs)
        , FSText ">"
        , fast m'
        , FSText ("</" <>  t <> ">")
        ]
  Text DoEscape t -> FBuilder (escape t)
  Text Don'tEscape t -> case t of
    StrictT a  -> FSText a
    LazyT a    -> FLText a
    BuilderT a -> FBuilder a
  List v -> Bunch (V.map fast (V.fromList v))
  Hole e v -> FHole e v
  Stream a -> FStream a
  Empty -> FEmpty

-- | Look for an immediate string-like term and render that
immediateRender :: FastMarkup a -> Maybe TLB.Builder
immediateRender fm = case fm of
  FBuilder t -> Just t
  FSText t   -> Just (TLB.fromText t)
  FLText t   -> Just (TLB.fromLazyText t)
  FEmpty     -> Just mempty
  _          -> Nothing

-- | Flatten a vector of 'FastMarkup. String-like terms that are next to
-- eachother should be combined
munch :: Vector (FastMarkup a) -> Vector (FastMarkup a)
munch v = V.fromList (go mempty 0)
  where
    len = V.length v
    go acc i
      | i < len =
        let e = V.unsafeIndex v i
        in case immediateRender e of
          Just b  -> go (acc <> b) (i + 1)
          Nothing -> FBuilder acc : e : go mempty (i + 1)
      | otherwise = [FBuilder acc]

data EqHack a = EqHack {-# UNPACK #-} !Int a

instance Eq (EqHack a) where
  EqHack i _ == EqHack j _ = i == j

-- | Tag everything in a 'Traversable' with a number
eqHack :: Traversable f => f a -> f (EqHack a)
eqHack = (`evalState` 0) . traverse (\x -> do
  i <- get
  modify' (+ 1)
  return (EqHack i x))

-- | Recursively flatten 'FastMarkup' until doing so does nothing
flatten :: FastMarkup a -> FastMarkup a
flatten fm = case fm of
  FStream t -> FStream t
  _         -> go

  where
    go = again $ case fm of
      Bunch v -> case V.length v of
        0 -> FEmpty
        1 -> V.head v
        _ -> Bunch
         (munch
          (V.concatMap
           (\x -> case x of
               Bunch v' -> v'
               FEmpty   -> V.empty
               _        -> V.singleton (flatten x))
           v))
      _ -> runIdentity (plateFM (Identity . flatten) fm)

    again a
      | eqHack a == eqHack fm = fm
      | otherwise = flatten a

-- | Run all Text builders
strictify :: FastMarkup a -> FastMarkup a
strictify fm = case fm of
  FBuilder t -> FLText (TLB.toLazyText t)
  FLText   t -> FLText t
  _          -> runIdentity (plateFM (Identity . strictify) fm)

-- | Compile 'Markup'''
compile_ :: Markup' a -> FastMarkup a
compile_ = strictify . flatten . fast

--------------------------------------------------------------------------------
-- Rendering

{-#
  SPECIALISE renderM :: (a -> Identity TLB.Builder)
                     -> FastMarkup a
                     -> Identity TLB.Builder
  #-}

{-# INLINABLE renderM #-}
-- | Render 'FastMarkup'
renderM :: Monad m => (a -> m TLB.Builder) -> FastMarkup a -> m TLB.Builder
renderM f = go
  where

    runStream (S s0 next fm) = rgo s0
      where
        rgo s' = case next s' of
          Next xs x -> mappend <$> go (fm x) <*> rgo xs
          Done x    -> go (fm x)

    runStream (ListS l f) = rgo l
      where
        rgo (x:xs) = mappend <$> go (f x) <*> rgo xs
        rgo _      = pure mempty

    go fm = case fm of
      Bunch v     -> V.foldM (\a b -> return (a <> b)) mempty =<< V.mapM go v
      FBuilder t  -> return t
      FSText t    -> return (TLB.fromText t)
      FLText t    -> return (TLB.fromLazyText t)
      FHole _ a   -> f a
      FStream str -> runStream str
      _           -> return mempty

{-# INLINE renderMs #-}
-- | Render 'FastMarkup' by recursively rendering any sub-markup.
renderMs :: Monad m => (a -> m (FastMarkup Void)) -> FastMarkup a -> m TLB.Builder
renderMs f = renderM (f >=> renderMs (f . absurd))

{-# INLINE render #-}
-- | Render 'FastMarkup' that has no holes.
render :: FastMarkup Void -> TLB.Builder
render = runIdentity . renderM absurd

class Render a m where
  r :: a -> m TLB.Builder

instance (Monad m, Render b m) => Render (a :$ b) m where
  {-# INLINE r #-}
  r (b :$ a) = renderM (\f -> r (f a)) b

instance Monad m => Render Void m where
  {-# INLINE r #-}
  r = return . absurd

instance Monad m => Render TLB.Builder m where
  {-# INLINE r #-}
  r = return

instance {-# OVERLAPPABLE #-} (Render a m, Monad m) => Render (FastMarkup a) m where
  {-# INLINE r #-}
  r = renderM r

