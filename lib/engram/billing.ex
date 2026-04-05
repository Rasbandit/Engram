defmodule Engram.Billing do
  @moduledoc """
  Billing context: Stripe checkout sessions, webhook processing, tier/trial queries.
  """

  import Ecto.Query
  alias Engram.Repo
  alias Engram.Billing.Subscription

  @trial_days 14

  # ── Tier & Status Queries ──────────────────────────────────────

  def tier(user) do
    case get_subscription(user) do
      %Subscription{status: status, tier: tier} when status in ~w(active past_due trialing) ->
        String.to_existing_atom(tier)

      _ ->
        :trial
    end
  end

  def active?(user) do
    case get_subscription(user) do
      %Subscription{status: status} when status in ~w(active past_due trialing) ->
        true

      _ ->
        in_trial?(user)
    end
  end

  def get_subscription(user) do
    Repo.one(
      from(s in Subscription, where: s.user_id == ^user.id),
      skip_tenant_check: true
    )
  end

  def trial_days_remaining(user) do
    elapsed = DateTime.diff(DateTime.utc_now(), user.inserted_at, :day)
    max(@trial_days - elapsed, 0)
  end

  defp in_trial?(user), do: trial_days_remaining(user) > 0

  # ── Checkout Session ───────────────────────────────────────────

  def create_checkout_session(user, tier) when tier in ~w(starter pro) do
    price_id = price_id_for(tier)

    params = %{
      mode: "subscription",
      line_items: [%{price: price_id, quantity: 1}],
      customer_email: user.email,
      client_reference_id: to_string(user.id),
      metadata: %{"tier" => tier},
      success_url: success_url(),
      cancel_url: cancel_url()
    }

    case Stripe.Checkout.Session.create(params) do
      {:ok, session} -> {:ok, session.url}
      {:error, error} -> {:error, error}
    end
  end

  # ── Customer Portal ────────────────────────────────────────────

  def create_portal_session(user) do
    case get_subscription(user) do
      %Subscription{stripe_customer_id: customer_id} ->
        case Stripe.BillingPortal.Session.create(%{
               customer: customer_id,
               return_url: return_url()
             }) do
          {:ok, session} -> {:ok, session.url}
          {:error, error} -> {:error, error}
        end

      nil ->
        {:error, :no_subscription}
    end
  end

  # ── Webhook Event Processing ───────────────────────────────────

  def upsert_from_stripe_event(%{
        "type" => "checkout.session.completed",
        "data" => %{"object" => session}
      }) do
    %{
      "customer" => customer_id,
      "subscription" => subscription_id,
      "client_reference_id" => user_id_str,
      "metadata" => %{"tier" => tier}
    } = session

    user_id = String.to_integer(user_id_str)

    attrs = %{
      user_id: user_id,
      stripe_customer_id: customer_id,
      stripe_subscription_id: subscription_id,
      tier: tier,
      status: "active"
    }

    %Subscription{}
    |> Subscription.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:stripe_customer_id, :stripe_subscription_id, :tier, :status, :updated_at]},
      conflict_target: :user_id,
      skip_tenant_check: true
    )
  end

  def upsert_from_stripe_event(%{
        "type" => type,
        "data" => %{"object" => sub_obj}
      })
      when type in ~w(customer.subscription.updated customer.subscription.deleted) do
    %{
      "id" => subscription_id,
      "status" => status,
      "current_period_end" => period_end_unix,
      "items" => %{"data" => [%{"price" => %{"id" => price_id}} | _]}
    } = sub_obj

    tier = tier_from_price_id(price_id)
    period_end = DateTime.from_unix!(period_end_unix)

    case Repo.one(
           from(s in Subscription, where: s.stripe_subscription_id == ^subscription_id),
           skip_tenant_check: true
         ) do
      %Subscription{} = sub ->
        sub
        |> Subscription.changeset(%{status: status, tier: tier, current_period_end: period_end})
        |> Repo.update(skip_tenant_check: true)

      nil ->
        {:error, :subscription_not_found}
    end
  end

  def upsert_from_stripe_event(_event), do: {:ok, :ignored}

  # ── Helpers ────────────────────────────────────────────────────

  defp price_id_for("starter"), do: Application.get_env(:engram, :stripe_starter_price_id)
  defp price_id_for("pro"), do: Application.get_env(:engram, :stripe_pro_price_id)

  defp tier_from_price_id(price_id) do
    cond do
      price_id == Application.get_env(:engram, :stripe_starter_price_id) -> "starter"
      price_id == Application.get_env(:engram, :stripe_pro_price_id) -> "pro"
      true -> "starter"
    end
  end

  defp success_url, do: EngramWeb.Endpoint.url() <> "/app/billing?success=true"
  defp cancel_url, do: EngramWeb.Endpoint.url() <> "/app/billing?canceled=true"
  defp return_url, do: EngramWeb.Endpoint.url() <> "/app/billing"
end
