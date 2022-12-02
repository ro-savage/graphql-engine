{-# LANGUAGE QuasiQuotes #-}

-- |
-- Tests for the behaviour of columns with default values.
--
-- https://hasura.io/docs/latest/schema/postgres/default-values/postgres-defaults/
-- https://hasura.io/docs/latest/schema/ms-sql-server/default-values/index/
module Test.Schema.DefaultValues.DefaultValuesSpec (spec) where

import Data.Aeson (Value)
import Data.List.NonEmpty qualified as NE
import Harness.Backend.Cockroach qualified as Cockroach
import Harness.Backend.Postgres qualified as Postgres
import Harness.Backend.Sqlserver qualified as Sqlserver
import Harness.GraphqlEngine (postGraphql, postGraphqlWithHeaders, postMetadata_)
import Harness.Quoter.Graphql (graphql)
import Harness.Quoter.Yaml (interpolateYaml, yaml)
import Harness.Test.Fixture qualified as Fixture
import Harness.Test.Schema (Table (..), table)
import Harness.Test.Schema qualified as Schema
import Harness.TestEnvironment (TestEnvironment)
import Harness.Yaml (shouldReturnYaml)
import Hasura.Prelude
import Test.Hspec (SpecWith, describe, it)

spec :: SpecWith TestEnvironment
spec =
  Fixture.run
    ( NE.fromList
        [ (Fixture.fixture $ Fixture.Backend Fixture.Postgres)
            { Fixture.setupTeardown = \(testEnvironment, _) ->
                [ Postgres.setupTablesAction schema testEnvironment,
                  setupMetadata Fixture.Postgres testEnvironment
                ]
            },
          (Fixture.fixture $ Fixture.Backend Fixture.SQLServer)
            { Fixture.setupTeardown = \(testEnvironment, _) ->
                [ Sqlserver.setupTablesAction schema testEnvironment,
                  setupMetadata Fixture.SQLServer testEnvironment
                ]
            },
          (Fixture.fixture $ Fixture.Backend Fixture.Cockroach)
            { Fixture.setupTeardown = \(testEnvironment, _) ->
                [ Cockroach.setupTablesAction schema testEnvironment,
                  setupMetadata Fixture.Cockroach testEnvironment
                ]
            }
        ]
    )
    tests

--------------------------------------------------------------------------------
-- Schema

schema :: [Schema.Table]
schema =
  [ (table "author")
      { tableColumns =
          [ Schema.column "uuid" Schema.TStr,
            Schema.column "name" Schema.TStr,
            Schema.column "company" Schema.TStr
          ],
        tablePrimaryKey = ["uuid"],
        tableData = []
      }
  ]

--------------------------------------------------------------------------------
-- Tests

tests :: Fixture.Options -> SpecWith TestEnvironment
tests opts = do
  let shouldBe :: IO Value -> Value -> IO ()
      shouldBe = shouldReturnYaml opts

  describe "Default values for inserts" do
    it "Uses default values" \testEnvironment -> do
      let expected :: Value
          expected =
            [yaml|
              data:
                insert_hasura_author:
                  returning:
                  - uuid: "36a6257b-1111-1111-1111-c1b7a7997087"
                    name: "Author 1"
                    company: "hasura"
            |]

          actual :: IO Value
          actual =
            postGraphqlWithHeaders
              testEnvironment
              [ ("X-Hasura-Role", "user"),
                ("X-Hasura-User-Id", "36a6257b-1111-1111-1111-c1b7a7997087")
              ]
              [graphql|
                mutation author {
                  insert_hasura_author(objects: [{ name: "Author 1" }]) {
                    returning {
                      uuid
                      name
                      company
                    }
                  }
                }
              |]

      actual `shouldBe` expected

    it "Hides columns with defaults from the schema" \testEnvironment -> do
      let expected :: Value
          expected =
            [yaml|
              errors:
              - extensions:
                  path: $.selectionSet.insert_hasura_author.args.objects[0].company
                  code: validation-failed
                message: |-
                  field 'company' not found in type: 'hasura_author_insert_input'
            |]

          actual :: IO Value
          actual =
            postGraphqlWithHeaders
              testEnvironment
              [ ("X-Hasura-Role", "user"),
                ("X-Hasura-User-Id", "36a6257b-1111-1111-1111-c1b7a7997087")
              ]
              [graphql|
                mutation author {
                  insert_hasura_author(objects: {
                    name: "Author 2",
                    company: "arusah"
                  }) {
                    returning {
                      uuid
                      name
                      company
                    }
                  }
                }
              |]

      actual `shouldBe` expected

    it "Hides columns with session-given defaults from the schema" \testEnvironment -> do
      let expected :: Value
          expected =
            [yaml|
              errors:
              - extensions:
                  path: $.selectionSet.insert_hasura_author.args.objects[0].uuid
                  code: validation-failed
                message: |-
                  field 'uuid' not found in type: 'hasura_author_insert_input'
            |]

          actual :: IO Value
          actual =
            postGraphqlWithHeaders
              testEnvironment
              [ ("X-Hasura-Role", "user"),
                ("X-Hasura-User-Id", "36a6257b-1111-1111-1111-c1b7a7997087")
              ]
              [graphql|
                mutation author {
                  insert_hasura_author(objects: {
                    name: "Author 3",
                    uuid: "36a6257b-1111-1111-2222-c1b7a7997087"
                  }) {
                    returning {
                      uuid
                      name
                      company
                    }
                  }
                }
              |]

      actual `shouldBe` expected

    it "Allows admin roles to insert into columns with defaults" \testEnvironment -> do
      let expected :: Value
          expected =
            [yaml|
              data:
                insert_hasura_author:
                  returning:
                  - uuid: "36a6257b-1111-1111-2222-c1b7a7997087"
                    name: "Author 4"
                    company: "Not Hasura"
            |]

          actual :: IO Value
          actual =
            postGraphql
              testEnvironment
              [graphql|
                mutation author {
                  insert_hasura_author(objects:
                    { name: "Author 4"
                      uuid: "36a6257b-1111-1111-2222-c1b7a7997087"
                      company: "Not Hasura"
                    }) {
                    returning {
                      uuid
                      name
                      company
                    }
                  }
                }
              |]

      actual `shouldBe` expected

--------------------------------------------------------------------------------
-- Metadata

setupMetadata :: Fixture.BackendType -> TestEnvironment -> Fixture.SetupAction
setupMetadata backendType testEnvironment = do
  let backendPrefix = Fixture.defaultBackendTypeString backendType
      source = Fixture.defaultSource backendType

      schemaName :: Schema.SchemaName
      schemaName = Schema.getSchemaName testEnvironment

      setup :: IO ()
      setup =
        postMetadata_
          testEnvironment
          [interpolateYaml|
            type: bulk
            args:
            - type: #{backendPrefix}_create_select_permission
              args:
                source: #{source}
                table:
                  schema: #{schemaName}
                  name: author
                role: user
                permission:
                  filter:
                    uuid: X-Hasura-User-Id
                  columns: '*'

            - type: #{backendPrefix}_create_insert_permission
              args:
                source: #{source}
                table:
                  schema: #{schemaName}
                  name: author
                role: user
                permission:
                  check: {}
                  set:
                    uuid: X-Hasura-User-Id
                    company: hasura
                  columns: '*'
          |]

      teardown :: IO ()
      teardown =
        postMetadata_
          testEnvironment
          [interpolateYaml|
            type: bulk
            args:
            - type: #{backendPrefix}_drop_select_permission
              args:
                source: #{source}
                table:
                  schema: #{schemaName}
                  name: author
                role: user
            - type: #{backendPrefix}_drop_insert_permission
              args:
                source: #{source}
                table:
                  schema: #{schemaName}
                  name: author
                role: user
          |]

  Fixture.SetupAction setup \_ -> teardown
