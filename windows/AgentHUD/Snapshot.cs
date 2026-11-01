using System.Text.Json;

namespace AgentHUD;

/// One line agenthud-core prints (`HeadlessSnapshot` in Core). Names, countdowns and amounts arrive in words.
public sealed record Snapshot(
    int Version,
    DateTimeOffset GeneratedAt,
    string Language,
    List<Row> Rows,
    List<Session> Sessions,
    List<Billing> Billing,
    double? MaxUsedPct,
    string? Level,
    List<string> WorkingVendors,
    bool IsLoading,
    string? Error)
{
    public const int SupportedVersion = 1;

    private static readonly JsonSerializerOptions Options = new() { PropertyNameCaseInsensitive = true };

    public static Snapshot? Parse(string line)
    {
        try { return JsonSerializer.Deserialize<Snapshot>(line, Options); }
        catch (JsonException) { return null; }
    }
}

public sealed record Row(
    string Id,
    string Vendor,
    string VendorName,
    string Name,
    string ShortName,
    double? UsedPct,
    double? WeeklyUsedPct,
    DateTimeOffset? ResetAt,
    string ResetLabel,
    string? Level,
    int PaletteIndex,
    bool IsCurrentAccount);

public sealed record Session(
    string Id,
    string AgentId,
    string? Vendor,
    string Title,
    string? Client,
    string? Project,
    string Status,
    bool IsLive,
    bool IsWaiting,
    long TokensIn,
    long TokensOut,
    DateTimeOffset StartedAt,
    DateTimeOffset ObservedAt);

public sealed record Billing(string Id, string Name, List<string> Balances);
