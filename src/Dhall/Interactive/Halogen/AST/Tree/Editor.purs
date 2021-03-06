module Dhall.Interactive.Halogen.AST.Tree.Editor where

import Prelude

import CSS as CSS
import CSS.Overflow as CSS.Overflow
import Control.Comonad (extract)
import Control.Monad.Writer (WriterT, runWriterT)
import Control.Plus (empty, (<|>))
import Data.Array (any, fold, intercalate)
import Data.Array as Array
import Data.Array.NonEmpty as NEA
import Data.Bifoldable (bifoldMap)
import Data.Const (Const)
import Data.Either (Either(..), either)
import Data.Foldable (for_, traverse_)
import Data.FunctorWithIndex (mapWithIndex)
import Data.HeytingAlgebra (tt)
import Data.Int as Int
import Data.Lens (Traversal', _2, (%=), (.=), (.~))
import Data.Lens as L
import Data.Lens.Iso.Newtype (_Newtype)
import Data.Lens.Record (prop)
import Data.List (List(..), (:))
import Data.List as List
import Data.Map (Map)
import Data.Maybe (Maybe(..), fromMaybe, isJust, maybe)
import Data.Monoid (guard)
import Data.Monoid.Additive (Additive(..))
import Data.Natural (Natural)
import Data.Newtype (un, unwrap, wrap)
import Data.These (These(..))
import Data.TraversableWithIndex (class TraversableWithIndex)
import Data.Tuple (Tuple(..), fst)
import Data.Variant as Variant
import Dhall.Core (Expr, Import, S_, _S)
import Dhall.Core as AST
import Dhall.Core.AST (ExprI, ExprRowVFI(..))
import Dhall.Core.AST.Noted as Ann
import Dhall.Core.AST.Operations.Location (Location, Derivation)
import Dhall.Core.AST.Operations.Location as Loc
import Dhall.Core.AST.Types.Basics (Three(..))
import Dhall.Core.Imports as Core.Imports
import Dhall.Core.Zippers (_ix)
import Dhall.Core.Zippers.Recursive (_recurse)
import Dhall.Interactive.Halogen.AST (SlottedHTML(..))
import Dhall.Interactive.Halogen.AST.Tree (AnnExpr, collapsible, mkActions, renderExprWith, renderImport, selectable)
import Dhall.Interactive.Halogen.Icons as Icons
import Dhall.Interactive.Halogen.Inputs (inline_feather_button_action)
import Dhall.Lib.Timeline (Timeline)
import Dhall.Lib.Timeline as Timeline
import Dhall.Map (InsOrdStrMap)
import Dhall.Map as Dhall.Map
import Dhall.Parser as Dhall.Parser
import Dhall.Printer (Line, TokenType(..), layoutAST, printLine')
import Dhall.TypeCheck (Errors, L, OxprE, TypeCheckError(..), Oxpr, oneStopShop)
import Dhall.TypeCheck.Errors (Reference(..))
import Dhall.TypeCheck.Operations (plain, topLoc, typecheckStep)
import Effect.Aff (Aff)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.CSS as HCSS
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Type.Row (type (+))
import Unsafe.Coerce (unsafeCoerce)
import Validation.These (Erroring(..))
import Web.Event.Event as Event
import Web.File.File as File
import Web.File.FileList as FileList
import Web.File.FileReader.Aff as FileReaderAff
import Web.HTML.HTMLInputElement as HTMLInputElement

type Ixpr = AnnExpr (Maybe Core.Imports.Import)
type EditState =
  { value :: Timeline Ixpr
  , views :: Array ViewId
  , nextView :: ViewId
  , userInput :: String
  -- , highlights :: Array { variety :: HighlightVariety, pos :: Derivation }
  , cache :: Map Import
    { text :: Maybe String
    , parsed :: Maybe (Expr InsOrdStrMap Import)
    , resolved :: Maybe (Expr InsOrdStrMap Void)
    }
  }
type ViewId = Natural
data GlobalActions = NoGlobalActions Void
data EditActions
  = Set Ixpr -- lowest common denominator: unsatisfactory, but works
  | Undo
  | Redo
  | NewView Location
  | DeleteView
  | RequestParsed
data EditQuery a
  = EditAction (Maybe ViewId) a EditActions
  | Output a -- output Ixpr to parent
  | Check (Ixpr -> a) -- check its current value
  | UserInput a String
  | FileChosen a Event.Event

type ERROR = Erroring (TypeCheckError (Errors + ( "Not found" :: ExprRowVFI )) (L Dhall.Map.InsOrdStrMap (Maybe Core.Imports.Import)))
type ViewState =
  { value :: Ixpr
  , view :: Location
  , selection :: Maybe ExprI
  }
type ViewRender =
  { st :: ViewState
  , window :: ERROR Ixpr
  , oxpr :: OxprE () ( "Not found" :: ExprRowVFI ) Dhall.Map.InsOrdStrMap (Maybe Core.Imports.Import)
  , explain ::
      TypeCheckError (Errors ( "Not found" :: ExprRowVFI )) (L Dhall.Map.InsOrdStrMap (Maybe Core.Imports.Import)) ->
      Array (Reference (Maybe (OxprE () ( "Not found" :: ExprRowVFI ) Dhall.Map.InsOrdStrMap (Maybe Core.Imports.Import))))
  , editable :: Boolean
  , exists :: Boolean
  , typechecks :: Boolean
  }
data ViewActions
  = Select (Maybe ExprI)
  | Un_Focus Int Location -- pop foci and move down to new location
  | SetSelection Ixpr -- set new Ixpr at selection
  | SetSelectionParsed
  | SetView Ixpr
data ViewQuery a
  = ViewInitialize a Location
  | ViewAction a (Array ViewActions)
  | Raise a EditActions
  | Receive a Ixpr
  | ReceiveParsed a Ixpr

hole :: AST.Expr Dhall.Map.InsOrdStrMap (Maybe Core.Imports.Import)
hole = pure Nothing

tpi :: Maybe Core.Imports.Import -> AST.Expr Dhall.Map.InsOrdStrMap (Maybe Core.Imports.Import)
tpi _ = hole

unWriterT :: forall m f a. Functor f => WriterT m f a -> f a
unWriterT = runWriterT >>> map fst

editor :: H.Component HH.HTML EditQuery Ixpr Ixpr Aff
editor = H.mkComponent
  { initialState: ({ userInput: "Type", nextView: one, views: [zero], cache: mempty, value: _ } <<< pure) :: Ixpr -> EditState
  , eval: H.mkEval $ H.defaultEval
      { handleAction = eval, handleQuery = map pure <<< eval
      , receive = Just <<< EditAction Nothing unit <<< Set
      }
  , render
  } where
    eval :: _ ~> _
    eval = case _ of
      Output a -> a <$ (H.gets _.value >>= extract >>> H.raise)
      Check a -> H.gets _.value <#> extract >>> a
      UserInput a userInput -> a <$ (prop (_S::S_ "userInput") .= userInput)
      FileChosen a ev -> a <$ do
        for_ (HTMLInputElement.fromEventTarget =<< Event.target ev) \input ->
          H.liftEffect (HTMLInputElement.files input) >>= traverse_ \files ->
            for_ (FileList.item 0 files) \file -> do
              content <- H.liftAff $ FileReaderAff.readAsText (File.toBlob file)
              eval (UserInput unit content)
      EditAction mviewId a act -> a <$ case act of
        Set value -> prop (_S::S_ "value") %= Timeline.happen value
        Undo -> prop (_S::S_ "value") %= (fromMaybe <*> Timeline.unhappen)
        Redo -> prop (_S::S_ "value") %= (fromMaybe <*> Timeline.rehappen)
        DeleteView -> for_ mviewId \viewId ->
          prop (_S::S_ "views") %= Array.delete viewId
        NewView view -> do
          prop (_S::S_ "nextView") %= add one
          viewId <- H.gets _.nextView
          prop (_S::S_ "views") %= flip Array.snoc viewId
          void $ H.query (_S::S_ "view") viewId $ ViewInitialize unit view
        RequestParsed -> for_ mviewId \viewId -> do
          userInput <- H.gets _.userInput
          let mparsed = Dhall.Parser.parse userInput <#> map Just >>> Ann.innote mempty
          for_ mparsed \parsed ->
            void $ H.query (_S::S_ "view") viewId $ ReceiveParsed unit parsed
    render :: EditState -> H.ComponentHTML (EditQuery Unit) ( view :: H.Slot ViewQuery EditActions Natural, format :: H.Slot _ _ _ ) Aff
    render { views, value, userInput } =
      let
        renderedViews = views <#> \viewId ->
          HH.slot (_S::S_ "view") viewId viewer
            (extract value)
            (Just <<< EditAction (Just viewId) unit)
        appendView = Just (EditAction Nothing unit (NewView empty))
        parsed = Dhall.Parser.parse userInput
      in HH.div [ HP.class_ (H.ClassName "expr-editor") ]
        [ HH.div_ renderedViews
        , HH.div_
          [ inline_feather_button_action appendView "plus-square" "Add a new view"
          , inline_feather_button_action (Timeline.unhappen value $> EditAction Nothing unit Undo) "corner-up-left" "Undo"
          , inline_feather_button_action (Timeline.rehappen value $> EditAction Nothing unit Redo) "corner-down-right" "Redo"
          ]
        , HH.textarea [ HE.onValueInput (Just <<< UserInput unit), HP.value userInput ]
        , Icons.icon (if isJust parsed then "check" else "x") [ Icons.class_ "feather" ]
        , HH.br_
        , HH.text "Upload file (replaces text in the above textarea): "
        , HH.input
          [ HP.type_ HP.InputFile
          , HP.multiple false
          , HE.onChange (Just <<< FileChosen unit)
          ]
        , HH.br_
        , HH.br_
        , HH.text "Formatted code: "
        , HH.slot (_S::S_ "format") unit formatter (extract value) (const Nothing)
        ]

data FormatAction
  = FormatExpr Ixpr
  | FormatLine Number
  | FormatWidth Number
  | FormatSoft Boolean
  | FormatAlign Boolean
  | FormatAscii Boolean
  | FormatScrolling Boolean
formatter :: H.Component HH.HTML (Const Void) Ixpr String Aff
formatter = H.mkComponent
  { initialState:
    { expr: _
    , view: { scrolling: true }
    , opts:
      { ascii: false
      , line: Just (Additive 40)
      , printImport: maybe "_" show
      , tabs:
        { width: Additive 2
        , soft: true
        , align: true
    } } }
  , eval: H.mkEval $ H.defaultEval
      { handleAction = eval
      , receive = Just <<< FormatExpr
      }
  , render
  } where
    eval :: FormatAction -> _
    eval = case _ of
      FormatExpr expr -> do
        expr_ <- H.gets _.expr
        when (expr_ /= expr) do
          prop (_S::S_ "expr") .= expr
      FormatLine v -> prop (_S::S_ "opts") <<< prop (_S::S_ "line") .=
        case Int.round v of
          i | i > 120 -> Nothing
          i -> Just (wrap i)
      FormatAscii v -> prop (_S::S_ "opts") <<< prop (_S::S_ "ascii") .= v
      FormatWidth v -> prop (_S::S_ "opts") <<< prop (_S::S_ "tabs") <<< prop (_S::S_ "width") .= wrap (Int.round v)
      FormatSoft v -> prop (_S::S_ "opts") <<< prop (_S::S_ "tabs") <<< prop (_S::S_ "soft") .= v
      FormatAlign v -> prop (_S::S_ "opts") <<< prop (_S::S_ "tabs") <<< prop (_S::S_ "align") .= v
      FormatScrolling v -> prop (_S::S_ "view") <<< prop (_S::S_ "scrolling") .= v
    render { expr, opts, view } = HH.div_
      [ HH.text "Width: "
      , HH.input
        [ HP.type_ HP.InputRange
        , HP.min 1.0, HP.max 121.0, HP.step (HP.Step 1.0)
        , HP.value $ maybe "121" (show <<< unwrap) opts.line
        , HE.onValueInput (Just <<< FormatLine <<< unsafeCoerce)
        , HCSS.style
          let ch i = CSS.Size (CSS.value i <> CSS.fromString "ch") in
          CSS.width (40.0 # ch)
        ]
      , HH.text $ " (" <> maybe "∞" (show <<< unwrap) opts.line <> ")"
      , HH.br_
      , HH.text "Tab width: "
      , HH.input
        [ HP.type_ HP.InputRange
        , HP.min 1.0, HP.max 8.0, HP.step (HP.Step 1.0)
        , HP.value $ (show <<< unwrap) opts.tabs.width
        , HE.onValueInput (Just <<< FormatWidth <<< unsafeCoerce)
        ]
      , HH.text $ " (" <> (show <<< unwrap) opts.tabs.width <> ")"
      , HH.br_
      , HH.text "Soft tabs: "
      , HH.input
        [ HP.type_ HP.InputCheckbox
        , HP.checked opts.tabs.soft
        , HE.onChecked (Just <<< FormatSoft)
        ]
      , HH.text " Align idents to tab stops: "
      , HH.input
        [ HP.type_ HP.InputCheckbox
        , HP.checked opts.tabs.align
        , HE.onChecked (Just <<< FormatAlign)
        ]
      , HH.text " ASCII: "
      , HH.input
        [ HP.type_ HP.InputCheckbox
        , HP.checked opts.ascii
        , HE.onChecked (Just <<< FormatAscii)
        ]
      , HH.text " Scrolling: "
      , HH.input
        [ HP.type_ HP.InputCheckbox
        , HP.checked view.scrolling
        , HE.onChecked (Just <<< FormatScrolling)
        ]
      , HH.br_
      , HH.pre
        [ HP.class_ (H.ClassName "code-preview")
        , HCSS.style do
            CSS.Overflow.overflow CSS.Overflow.overflowAuto
            for_ opts.line \w ->
              let ch i = CSS.Size (CSS.value i <> CSS.fromString "ch") in
              CSS.width (unwrap w # Int.toNumber # ch)
            when view.scrolling do
              CSS.height (300.0 # CSS.px)
        ] $ map (renderLine <<< _.value) $ layoutAST opts (Ann.denote expr)
      ]
    renderTok :: forall r w i.
      { value :: String, tokType :: TokenType | r } ->
      HH.HTML w i
    renderTok { value, tokType }=
      let
        ttcls = case tokType of
          TTGrouping -> "token-grouping"
          TTSeparator -> "token-separator"
          TTOperator -> "token-operator"
          TTLiteral -> "token-literal"
          TTKeyword -> "token-keyword"
          TTImport -> "token-import"
          (TTName false) -> "token-name"
          (TTName true) -> "token-name token-builtin"
      in HH.span [ HP.class_ (H.ClassName ttcls) ] [ HH.text value ]
    renderLine :: forall w i. Line -> HH.HTML w i
    renderLine = HH.p_ <<<
      printLine' [ renderTok { value: " ", tokType: TTSeparator } ] <<<
      map \{ spaceBefore, spaceAfter, value, tokType } ->
        { spaceBefore, spaceAfter
        , value: [ renderTok { value, tokType } ]
        }


_ixes_Ann :: forall m s a. TraversableWithIndex String m =>
  ExprI -> Traversal' (Ann.Expr m s a) (Ann.Expr m s a)
_ixes_Ann Nil = identity
_ixes_Ann (i : is) = _ixes_Ann is <<< _recurse <<< _Newtype <<< _2 <<< _ix (extract i)

viewer :: H.Component HH.HTML ViewQuery Ixpr EditActions Aff
viewer = H.mkComponent
  { initialState: \value ->
    { value
    , view: empty
    , selection: pure empty
    } :: ViewState
  , eval: H.mkEval $ H.defaultEval
      { handleAction = eval, handleQuery = map pure <<< eval
      , receive = Just <<< Receive unit
      }
  , render: renderInfo >>> render
  } where
    eval :: _ ~> _
    eval = case _ of
      ViewInitialize a view -> a <$ do
        prop (_S::S_ "view") .= view
      Receive a value -> a <$ do
        prop (_S::S_ "value") .= value
      ReceiveParsed a parsed ->
        eval (ViewAction a [SetSelection parsed])
      Raise a edit -> a <$ H.raise edit
      ViewAction a acts -> a <$ for_ acts case _ of
        Select loc -> prop (_S::S_ "selection") .= loc
        Un_Focus up down -> do
          prop (_S::S_ "view") %= \view -> down <> List.drop up view
          -- TODO: adapt selection in a smart manner (common prefix)
          when (not List.null down) do prop (_S::S_ "selection") .= Nothing
        SetView patch -> do
          { value: old, view } <- H.get
          case Loc.allWithin view of
            Just loc' | loc <- map pure loc', L.has (_ixes_Ann loc) old ->
              let new = (_ixes_Ann loc .~ patch) old in
              when (new /= old) $ H.raise $ Set new
            _ -> pure unit
        SetSelectionParsed -> do
          H.raise RequestParsed
        SetSelection patch -> do
          { value: old, view, selection } <- H.get
          case Loc.allWithin view, selection of
            Just loc', Just sel | loc <- sel <> map pure loc', L.has (_ixes_Ann loc) old ->
              let new = (_ixes_Ann loc .~ patch) old in
              when (new /= old) $ H.raise $ Set new
            _, _ -> pure unit
    renderInfo :: ViewState -> ViewRender
    renderInfo st =
      let
        steps = (Variant.expand <$> st.view)
        base = oneStopShop (pure <<< tpi) (Ann.denote st.value)
        to = unWriterT $ base.locate (pure (Tuple steps Nothing))
        typeof = unWriterT <<< typecheckStep =<< to
        window = Ann.innote mempty <<< plain <$> to
      in
        { st, window
        , oxpr: base.oxpr
        , explain: base.explain
            {- <<< (map <<< map) case _ of
            Tuple l Nothing -> Tuple (l <> steps) Nothing
            Tuple l (Just e) -> Tuple l (Just e)
            -}
        , editable: isJust (Loc.allWithin st.view)
        , exists: any tt window
        , typechecks: any tt typeof
        }
    render :: ViewRender -> HH.ComponentHTML (ViewQuery Unit) () Aff
    render r = HH.div [ HP.class_ (H.ClassName "expr-viewer") ]
      [ HH.div [ HP.class_ (H.ClassName "header") ]
        [ inline_feather_button_action (Just (Raise unit DeleteView)) "x-square" "Close this view"
        , HH.text " "
        , renderLocation r.st.view <#> \i -> ViewAction unit [Un_Focus i empty]
        ]
      , case r.window of
          Success flowers -> un SlottedHTML $
            let
              opts = { interactive: true, editable: r.editable }
              selectHere = mkActions $ unwrap >>> extract >>> extract >>> \i ->
                let here = (Variant.inj (_S::S_ "within") <<< extract <$> i)
                    focus loc = Just \_ -> This $ Un_Focus zero loc
                in
                [ { icon: "at-sign"
                  , action: focus here
                  , tooltip: "Move view here"
                  }
                , { icon: "cpu"
                  , action: focus (Variant.inj (_S::S_ "normalize") {} : here)
                  , tooltip: "View this node, normalized"
                  }
                , { icon: "type"
                  , action: focus (Variant.inj (_S::S_ "typecheck") {} : here)
                  , tooltip: "View the type of this node"
                  }
                , { icon: "underline"
                  , action: focus (Variant.inj (_S::S_ "alphaNormalize") {} : here)
                  , tooltip: "Alpha normalized"
                  }
                ]
            in
            (renderExprWith <*> renderImport) opts
            (selectable opts { interactive = true } r.st.selection Select <> selectHere <> collapsible opts { interactive = false })
            flowers <#> ViewAction unit <<< bifoldMap pure (pure <<< SetView)
          Error errors' _ | errors <- NEA.toArray errors' ->
            HH.ul [ HP.class_ (H.ClassName "errors") ] $ errors <#>
              \t@(TypeCheckError { location, tag }) -> let errorName = (unsafeCoerce tag)."type" in
                HH.li  [ HP.class_ (H.ClassName "error-display") ]
                  [ HH.h3 [ HP.class_ (H.ClassName "error-name") ] [ HH.text errorName ]
                  , HH.div [ HP.class_ (H.ClassName "error-location") ] [ renderLoc (fst $ extract location) ]
                  , renderReferences renderErrorRef (r.explain t)
                  ]
      , HH.div [ HP.class_ (H.ClassName "edit-bar") ] $ guard (r.editable && isJust r.st.selection) $
        [ inline_feather_button_action (Just (ViewAction unit [SetSelection (Ann.innote mempty $ pure Nothing)])) "trash-2" "Delete this node"
        , HH.text " "
        , inline_feather_button_action (Just (ViewAction unit [SetSelectionParsed])) "edit-3" "Replace this node with parsed content"
        -- TODO: scroll to node?
        , inline_feather_button_action Nothing "at-sign" "editing at …"
        , renderLocation (Variant.inj (_S::S_ "within") <<< extract <$> fold r.st.selection) <#>
            \i -> ViewAction unit $ pure $ Select $ List.drop i <$> r.st.selection
        ]
      ]

renderLocation :: forall p. Location -> HH.HTML p Int
renderLocation loc = HH.span [ HP.class_ (H.ClassName "location") ] $
  intercalate [ HH.span [ HP.class_ (H.ClassName "breadcrumb-sep") ] [] ] $
    let len = List.length loc in
    (<|>) (pure $ pure $ inline_feather_button_action (Just len) "home" "Top of expression") $
    List.reverse loc # mapWithIndex \i -> pure <<<
      let act = Just (len - i - 1) in
      Variant.match
        { within: HH.button [ HE.onClick (pure act) ] <<< pure <<< renderERVFI
        , alphaNormalize: \_ -> inline_feather_button_action act "underline" "Alpha normalized"
        , normalize: \_ -> inline_feather_button_action act "cpu" "Normalized"
        , typecheck: \_ -> inline_feather_button_action act "type" "Typechecked"
        }

renderLoc :: forall p q. Derivation -> HH.HTML p q
renderLoc loc = HH.span [ HP.class_ (H.ClassName "location") ] $
  intercalate [ HH.span [ HP.class_ (H.ClassName "breadcrumb-sep") ] [] ] $
    (<|>) (pure $ pure $ inline_feather_button_action Nothing "home" "Top of expression") $
    List.reverse loc # mapWithIndex \i -> pure <<<
      Variant.match
        { within: ($) renderERVFI
        , alphaNormalize: \_ -> inline_feather_button_action Nothing "underline" "Alpha normalized"
        , normalize: \_ -> inline_feather_button_action Nothing "cpu" "Normalized"
        , typecheck: \_ -> inline_feather_button_action Nothing "type" "Typechecked"
        , shift: \{ variable, delta } -> HH.text $ "↑(" <> show variable <> ", " <> show delta <> ")"
        , substitute: \_ -> inline_feather_button_action Nothing "cloud-snow" "After Substitution"
        }

renderErrorRef :: forall w r.
  Maybe (Oxpr w r Dhall.Map.InsOrdStrMap (Maybe Core.Imports.Import)) ->
  H.ComponentHTML (ViewQuery Unit) () Aff
renderErrorRef Nothing = HH.text "(missing)"
renderErrorRef (Just oxpr) = case extract $ topLoc oxpr of
  Tuple path Nothing -> HH.div_
    [ renderLoc path
    , un SlottedHTML $
      (renderExprWith <*> renderImport) { interactive: false, editable: false } mempty (Ann.innote mempty $ plain oxpr)
      <#> ViewAction unit <<< bifoldMap pure (pure <<< SetView)
    ]
  -- the path is not helpful if the focus is made up
  Tuple _ (Just _) -> HH.div_
    [ un SlottedHTML $
      (renderExprWith <*> renderImport) { interactive: false, editable: false } mempty (Ann.innote mempty $plain oxpr)
      <#> ViewAction unit <<< bifoldMap pure (pure <<< SetView)
    ]

renderERVFI :: forall p q. ExprRowVFI -> HH.HTML p q
renderERVFI ervfi = HH.span [ HP.class_ (H.ClassName "index") ]
  [ HH.span [ HP.class_ (H.ClassName "type") ] [ HH.text (unsafeCoerce ervfi)."type" ]
  , HH.text " "
  , HH.span [ HP.class_ (H.ClassName "tag") ] [ HH.text (tagERVFI ervfi) ]
  ]

renderReferences ::
  forall p q a. (a -> HH.HTML p q) -> Array (Reference a) -> HH.HTML p q
renderReferences renderA as = HH.div [ HP.class_ (H.ClassName "references") ] $
  map (renderReference <<< map renderA) as

renderReference :: forall p q. Reference (HH.HTML p q) -> HH.HTML p q
renderReference = case _ of
  Text desc -> HH.text desc
  Br -> HH.br_
  Href link text -> HH.a [ HP.href link ] [ HH.text text ]
  Reference a -> HH.div [ HP.class_ (H.ClassName "reference") ] [ a ]
  List as -> HH.ol [ HP.class_ (H.ClassName "reference-list") ] $ as <#> \a ->
    HH.li [ HP.class_ (H.ClassName "reference-item") ] [ renderReference a ]
  Compare sl l sr r -> HH.div [ HP.class_ (H.ClassName "reference-compare") ]
    [ HH.div [ HP.class_ (H.ClassName "reference-compare-left") ]
      [ HH.div [ HP.class_ (H.ClassName "reference-compare-title") ] [ HH.text sl ]
      , HH.div [ HP.class_ (H.ClassName "reference-compare-body") ] [ l ]
      ]
    , HH.div [ HP.class_ (H.ClassName "reference-compare-right") ]
      [ HH.div [ HP.class_ (H.ClassName "reference-compare-title") ] [ HH.text sr ]
      , HH.div [ HP.class_ (H.ClassName "reference-compare-body") ] [ r ]
      ]
    ]

tagERVFI :: ExprRowVFI -> String
tagERVFI = un ERVFI >>> Variant.match
  { "BoolLit": identity absurd
  , "NaturalLit": identity absurd
  , "IntegerLit": identity absurd
  , "DoubleLit": identity absurd
  , "Bool": identity absurd
  , "Natural": identity absurd
  , "Integer": identity absurd
  , "Double": identity absurd
  , "Text": identity absurd
  , "List": identity absurd
  , "Optional": identity absurd
  , "Const": identity absurd
  , "NaturalFold": identity absurd
  , "NaturalBuild": identity absurd
  , "NaturalIsZero": identity absurd
  , "NaturalEven": identity absurd
  , "NaturalOdd": identity absurd
  , "NaturalToInteger": identity absurd
  , "NaturalShow": identity absurd
  , "NaturalSubtract": identity absurd
  , "IntegerShow": identity absurd
  , "IntegerToDouble": identity absurd
  , "DoubleShow": identity absurd
  , "ListBuild": identity absurd
  , "ListFold": identity absurd
  , "ListLength": identity absurd
  , "ListHead": identity absurd
  , "ListLast": identity absurd
  , "ListIndexed": identity absurd
  , "ListReverse": identity absurd
  , "OptionalFold": identity absurd
  , "OptionalBuild": identity absurd
  , "TextShow": identity absurd
  , "TextLit": \i -> "interp@" <> show i
  , "ListLit":
      either (\(_ :: Unit) -> "type")
      \i -> "value@" <> show i
  , "Some": \(_ :: Unit) -> "value"
  , "None": identity absurd
  , "RecordLit": \(k :: String) -> "values@" <> show k
  , "Record": \(k :: String) -> "types@" <> show k
  , "Union": \(Tuple (k :: String) (_ :: Unit)) -> "types@" <> show k
  , "BoolAnd": binop
  , "BoolOr": binop
  , "BoolEQ": binop
  , "BoolNE": binop
  , "NaturalPlus": binop
  , "NaturalTimes": binop
  , "TextAppend": binop
  , "ListAppend": binop
  , "Combine": binop
  , "CombineTypes": binop
  , "Prefer": binop
  , "ImportAlt": binop
  , "UsingHeaders": binop
  , "Equivalent": binop
  , "Hashed": \(_ :: Unit) -> "expr"
  , "BoolIf": case _ of
      Three1 -> "if"
      Three2 -> "then"
      Three3 -> "else"
  , "Field": \(_ :: Unit) -> "expr"
  , "Project": case _ of
      Left (_ :: Unit) -> "expr"
      Right (_ :: Unit) -> "fields"
  , "Merge": case _ of
      Three1 -> "handlers"
      Three2 -> "arg"
      Three3 -> "type"
  , "ToMap": case _ of
      Left (_ :: Unit) -> "expr"
      Right (_ :: Unit) -> "type"
  , "Assert": \(_ :: Unit) -> "assertion"
  , "App": not >>> if _ then "fn" else "arg"
  , "Annot": not >>> if _ then "value" else "type"
  , "Lam": not >>> if _ then "type" else "body"
  , "Pi": not >>> if _ then "type" else "body"
  , "Let": case _ of
      Three1 -> "type"
      Three2 -> "value"
      Three3 -> "body"
  , "Var": identity absurd
  , "Embed": identity absurd
  } where
    binop = if _ then "R" else "L"
