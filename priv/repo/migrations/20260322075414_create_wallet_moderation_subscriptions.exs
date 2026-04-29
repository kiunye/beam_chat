defmodule BeamChat.Repo.Migrations.CreateWalletModerationSubscriptions do
  use Ecto.Migration

  def change do
    create table(:wallets, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :balance, :decimal, precision: 12, scale: 2, null: false, default: fragment("0")
      add :currency, :text, null: false, default: "KES"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:wallets, [:user_id])

    create constraint(:wallets, :wallet_non_negative, check: "balance >= 0")

    create table(:wallet_transactions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :wallet_id, references(:wallets, type: :binary_id, on_delete: :delete_all), null: false
      add :type, :text, null: false
      add :amount, :decimal, precision: 12, scale: 2, null: false
      add :balance_after, :decimal, precision: 12, scale: 2, null: false
      add :description, :text, null: false
      add :reference, :text
      add :provider, :text
      add :metadata, :map, null: false, default: fragment("'{}'::jsonb")
      add :status, :text, null: false, default: "pending"

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create constraint(:wallet_transactions, :wallet_transactions_type_check,
             check: "type IN ('credit','debit')"
           )

    create constraint(:wallet_transactions, :wallet_transactions_amount_positive,
             check: "amount > 0"
           )

    create constraint(:wallet_transactions, :wallet_transactions_status_check,
             check: "status IN ('pending','completed','failed','reversed')"
           )

    create constraint(:wallet_transactions, :wallet_transactions_provider_check,
             check: "provider IS NULL OR provider IN ('mpesa','paystack','internal')"
           )

    create unique_index(:wallet_transactions, [:reference],
             name: :wallet_transactions_reference_unique,
             where: "reference IS NOT NULL"
           )

    create index(:wallet_transactions, [:wallet_id, :inserted_at], name: :wallet_txn_wallet_idx)

    create table(:moderation_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :target_type, :text, null: false
      add :target_id, :binary_id, null: false
      add :action, :text, null: false
      add :reason, :text
      add :rule_id, :text
      add :actor_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :metadata, :map, null: false, default: fragment("'{}'::jsonb")

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create constraint(:moderation_logs, :moderation_logs_target_type_check,
             check: "target_type IN ('message','user','room')"
           )

    create table(:moderation_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :type, :text, null: false
      add :config, :map, null: false, default: fragment("'{}'::jsonb")
      add :is_active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create constraint(:moderation_rules, :moderation_rules_type_check,
             check: "type IN ('word_filter','rate_limit','link_filter','pattern')"
           )

    create table(:group_subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false

      add :wallet_txn_id,
          references(:wallet_transactions, type: :binary_id, on_delete: :nilify_all)

      add :started_at, :utc_datetime, null: false, default: fragment("now()")
      add :expires_at, :utc_datetime, null: false
      add :status, :text, null: false, default: "active"
    end

    create unique_index(:group_subscriptions, [:user_id, :room_id, :started_at])

    create constraint(:group_subscriptions, :group_subscriptions_status_check,
             check: "status IN ('active','expired','cancelled')"
           )

    create index(:group_subscriptions, [:expires_at],
             name: :subs_expiry_idx,
             where: "status = 'active'"
           )
  end
end
