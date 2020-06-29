let upstream =
      https://github.com/purescript/package-sets/releases/download/psc-0.13.8/packages.dhall sha256:0e95ec11604dc8afc1b129c4d405dcc17290ce56d7d0665a0ff15617e32bbf03

let overrides =
      { halogen = upstream.halogen // { version = "v5.0.2" }
      , variant =
              upstream.variant
          //  { version = "481fe28029e6ac8c25da647c6f797c8edfe3dbaf"
              , repo =
                  "https://github.com/MonoidMusician/purescript-variant.git"
              }
      }

let additions =
      { matryoshka =
        { dependencies =
          [ "fixed-points"
          , "free"
          , "prelude"
          , "profunctor"
          , "transformers"
          ]
        , repo =
            "https://github.com/purescript-contrib/purescript-matryoshka.git"
        , version = "6e9c8968c20573ee27bf80069e3135c180cbe9da"
        }
      , textcursor =
        { dependencies =
          [ "newtype"
          , "prelude"
          , "profunctor-lenses"
          , "web-uievents"
          ]
        , repo = "https://github.com/MonoidMusician/purescript-textcursor.git"
        , version = "3a9ace223f895f6cfa067ac523c95cf0fb8783d1"
        }
      , halogen-textcursor =
        { dependencies =
          [ "halogen"
          , "halogen-css"
          , "numbers"
          , "prelude"
          , "textcursor"
          ]
        , repo =
            "https://github.com/MonoidMusician/purescript-halogen-textcursor.git"
        , version = "ab65656ebcdac1ad22492013663d96bc3e415aaa"
        }
      , halogen-zuruzuru =
        { dependencies =
          [ "halogen"
          , "prelude"
          , "profunctor-lenses"
          ]
        , repo =
            "https://github.com/MonoidMusician/purescript-halogen-zuruzuru.git"
        , version = "dcd3896de9e7aa3dac441c0513c24393a5b4e5e8"
        }
      }

in  upstream // overrides // additions
