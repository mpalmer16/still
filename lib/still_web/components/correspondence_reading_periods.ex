defmodule StillWeb.CorrespondenceReadingPeriods do
  @moduledoc "Monthly timeline for recorded journal submission dates."
  use StillWeb, :html

  attr :model, :map, required: true
  attr :problem, :string, default: nil
  attr :searching, :boolean, default: false

  def timeline(assigns) do
    ~H"""
    <section
      id="reading-periods-timeline"
      class="reading-periods-timeline"
      aria-label="Reading periods"
      style={axis_style(@model)}
    >
      <p :if={@problem} role="alert" class="corr-calendar-empty">{@problem}</p>

      <%= if @model do %>
        <div :if={@model.rows != []} class="reading-periods-axis" aria-hidden="true">
          <div class="reading-periods-axis-scale">
            <span :if={@model.today} class="reading-period-today">
              Today · {short_date(@model.today)}
            </span>
            <span class="reading-periods-tick-first">{short_date(@model.month)}</span>
            <span
              :for={day <- [8, 15, 22]}
              class="reading-periods-tick"
              style={position("--reading-period-position", day - 1, @model.days)}
            >{day}</span>
            <span class="reading-periods-tick-last">{@model.days}</span>
          </div>
        </div>

        <ul
          :if={@model.rows != []}
          id="reading-periods-dated"
          class="reading-periods-list"
          aria-label="Journals with recorded submission dates"
        >
          <li :for={row <- @model.rows} class="reading-period-row" data-status={row.status}>
            <div class="reading-period-details">
              <.link
                patch={~p"/correspondence/journals/#{row.place.id}"}
                class="reading-period-name"
              >{row.place.name}</.link>
              <div class="reading-period-dates">{range_label(row.start_date, row.end_date)}</div>
              <div class="reading-period-status">{status_label(row)}</div>
            </div>
            <div class="reading-period-track" aria-hidden="true">
              <span
                class={[
                  "reading-period-range",
                  row.bar.continues_before? && "continues-before",
                  row.bar.continues_after? && "continues-after"
                ]}
                style={bar_style(row.bar, @model.days)}
              ></span>
            </div>
          </li>
        </ul>
        <p :if={@model.rows == []} class="corr-calendar-empty">
          {if @searching,
            do: "No dated reading periods match your search this month.",
            else: "No journals with recorded submission dates this month."}
        </p>

        <div
          :if={@model.year_round != [] || @model.dates_to_confirm != []}
          class="reading-periods-other"
        >
          <section
            :if={@model.year_round != []}
            id="reading-periods-year-round"
            aria-labelledby="reading-periods-year-round-heading"
          >
            <h3 id="reading-periods-year-round-heading">Open year-round</h3>
            <ul>
              <li :for={place <- @model.year_round}>
                <.link patch={~p"/correspondence/journals/#{place.id}"}>{place.name}</.link>
              </li>
            </ul>
          </section>
          <section
            :if={@model.dates_to_confirm != []}
            id="reading-periods-unconfirmed"
            aria-labelledby="reading-periods-unconfirmed-heading"
          >
            <h3 id="reading-periods-unconfirmed-heading">Dates to confirm</h3>
            <ul>
              <li :for={place <- @model.dates_to_confirm}>
                <.link patch={~p"/correspondence/journals/#{place.id}"}>{place.name}</.link>
                <p :if={place.windows not in [nil, ""]} class="reading-period-note">
                  {place.windows}
                </p>
              </li>
            </ul>
          </section>
        </div>
      <% end %>
    </section>
    """
  end

  defp axis_style(nil), do: nil

  defp axis_style(%{days: days, today: today}) do
    week = position("--reading-period-week", 7, days)

    if today,
      do: week <> "; " <> position("--reading-period-today", today.day - 0.5, days),
      else: week
  end

  defp bar_style(bar, days) do
    position("--reading-period-start", bar.left, days) <>
      "; " <> position("--reading-period-width", bar.span, days)
  end

  defp position(name, days, month_length),
    do: "#{name}: #{Float.round(days * 100 / month_length, 4)}%"

  defp short_date(date), do: Calendar.strftime(date, "%b %-d")

  defp range_label(day, day), do: short_date(day)

  defp range_label(first, last) when first.year == last.year,
    do: "#{short_date(first)}–#{short_date(last)}"

  defp range_label(first, last),
    do: "#{Calendar.strftime(first, "%b %-d, %Y")}–#{Calendar.strftime(last, "%b %-d, %Y")}"

  defp status_label(%{status: :open}), do: "Open today"
  defp status_label(%{status: :upcoming, start_date: date}), do: "Opens #{short_date(date)}"
  defp status_label(%{status: :closed}), do: "Closed"
end
