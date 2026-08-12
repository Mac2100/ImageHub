using System;
using System.Collections.Generic;
using System.Text.Json.Serialization;
using ImageHub.Support;

namespace ImageHub.Models;

// Every raw value here is the string the macOS app writes, because template JSON
// travels between the two and Provision.ps1 reads several of these verbatim. The
// first member of each enum is also its decoding fallback, which keeps a template
// that predates a setting behaving the way it did before.

[JsonConverter(typeof(RawEnumConverter<WindowsRelease>))]
public enum WindowsRelease
{
    [Raw("win11")] Win11,
    [Raw("win10")] Win10,
}

[JsonConverter(typeof(RawEnumConverter<WindowsEdition>))]
public enum WindowsEdition
{
    [Raw("pro")] Pro,
    [Raw("proWorkstations")] ProWorkstations,
    [Raw("enterprise")] Enterprise,
    [Raw("education")] Education,
    [Raw("proEducation")] ProEducation,
    [Raw("home")] Home,
}

[JsonConverter(typeof(RawEnumConverter<ProductKeyMode>))]
public enum ProductKeyMode
{
    // Declaration order is picker order, so the mode that needs no extra
    // infrastructure comes first and "no key at all" comes last.
    [Raw("firmware")] Firmware,
    [Raw("generic")] Generic,
    [Raw("custom")] Custom,
    [Raw("none")] None,
}

[JsonConverter(typeof(RawEnumConverter<ActivationMode>))]
public enum ActivationMode
{
    [Raw("automatic")] Automatic,
    [Raw("kms")] Kms,
    [Raw("skip")] Skip,
}

[JsonConverter(typeof(RawEnumConverter<PartitionStyle>))]
public enum PartitionStyle
{
    [Raw("gpt")] Gpt,
    [Raw("mbr")] Mbr,
}

[JsonConverter(typeof(RawEnumConverter<EndUserMode>))]
public enum EndUserMode
{
    /// <summary>Let the person who receives the machine complete Windows OOBE themselves.</summary>
    [Raw("leaveOOBE")] LeaveOobe,

    /// <summary>Pre-create a named local account from the template.</summary>
    [Raw("createLocalAccount")] CreateLocalAccount,

    /// <summary>Pause at a small ImageHub prompt on first boot and create the account then.</summary>
    [Raw("promptAtFirstBoot")] PromptAtFirstBoot,
}

[JsonConverter(typeof(RawEnumConverter<JoinMode>))]
public enum JoinMode
{
    [Raw("workgroup")] Workgroup,
    [Raw("activeDirectory")] ActiveDirectory,

    /// <summary>Leave the device unjoined so Entra ID / Intune enrolment happens at OOBE.</summary>
    [Raw("entraAtOOBE")] EntraAtOobe,
}

[JsonConverter(typeof(RawEnumConverter<AppSource>))]
public enum AppSource
{
    [Raw("winget")] Winget,
    [Raw("installer")] Installer,
    [Raw("script")] Script,
}

[JsonConverter(typeof(RawEnumConverter<RegistryValueType>))]
public enum RegistryValueType
{
    [Raw("DWord")] DWord,
    [Raw("QWord")] QWord,
    [Raw("String")] String,
    [Raw("ExpandString")] ExpandString,
    [Raw("MultiString")] MultiString,
}

[JsonConverter(typeof(RawEnumConverter<PowerPlan>))]
public enum PowerPlan
{
    [Raw("balanced")] Balanced,
    [Raw("highPerformance")] HighPerformance,
    [Raw("powerSaver")] PowerSaver,
}

[JsonConverter(typeof(RawEnumConverter<LidAction>))]
public enum LidAction
{
    [Raw("doNothing")] DoNothing,
    [Raw("sleep")] Sleep,
    [Raw("hibernate")] Hibernate,
    [Raw("shutDown")] ShutDown,
}

[JsonConverter(typeof(RawEnumConverter<UpdatePolicy>))]
public enum UpdatePolicy
{
    [Raw("automatic")] Automatic,
    [Raw("notifyBeforeDownload")] NotifyBeforeDownload,
    [Raw("disableAutomaticRestart")] DisableAutomaticRestart,
}

[JsonConverter(typeof(RawEnumConverter<BitLockerMode>))]
public enum BitLockerMode
{
    [Raw("off")] Off,
    [Raw("tpmOnly")] TpmOnly,
    [Raw("tpmWithPin")] TpmWithPin,
}

[JsonConverter(typeof(RawEnumConverter<ScriptPhase>))]
public enum ScriptPhase
{
    /// <summary>Runs inside Windows Setup's specialize pass, before first logon.</summary>
    [Raw("specialize")] Specialize,

    /// <summary>Runs during ImageHub provisioning, after apps and config.</summary>
    [Raw("provision")] Provision,

    /// <summary>Runs at the very end, right before the completion screen.</summary>
    [Raw("finalize")] Finalize,
}

[JsonConverter(typeof(RawEnumConverter<ImageOrigin>))]
public enum ImageOrigin
{
    [Raw("microsoft")] Microsoft,
    [Raw("imported")] Imported,
    [Raw("remoteURL")] RemoteUrl,
}

/// <summary>Which part of a template a problem belongs to, so the editor can jump there.</summary>
public enum TemplateField
{
    Windows,
    Disk,
    Accounts,
    Apps,
    System,
    FirstBoot,
    Scripts,
}

/// <summary>Labels for the enums above. Kept out of the enums so the wire format stays obvious.</summary>
public static class Labels
{
    public static string Of(WindowsRelease value) => value switch
    {
        WindowsRelease.Win10 => "Windows 10",
        _ => "Windows 11",
    };

    public static string Of(WindowsEdition value) => value switch
    {
        WindowsEdition.Pro => "Pro",
        WindowsEdition.ProWorkstations => "Pro for Workstations",
        WindowsEdition.Enterprise => "Enterprise",
        WindowsEdition.Education => "Education",
        WindowsEdition.ProEducation => "Pro Education",
        WindowsEdition.Home => "Home",
        _ => value.ToString(),
    };

    public static string Of(ProductKeyMode value) => value switch
    {
        ProductKeyMode.None => "None (choose at Setup)",
        ProductKeyMode.Firmware => "The PC's built-in key (OEM)",
        ProductKeyMode.Generic => "Generic edition key (KMS)",
        ProductKeyMode.Custom => "Specific key",
        _ => value.ToString(),
    };

    public static string Detail(ProductKeyMode value) => value switch
    {
        ProductKeyMode.None =>
            "No key goes into the answer file and Setup asks for one. Only useful if a "
            + "technician is standing there.",
        ProductKeyMode.Firmware =>
            "Nothing is written into the answer file, so Windows uses the OEM key in the "
            + "PC's firmware or its digital licence and activates on its own. Right for "
            + "machines that came with Windows preinstalled. The edition is still pinned "
            + "by image name, not by the key.",
        ProductKeyMode.Generic =>
            "Microsoft's public KMS client key for this edition. It selects the edition "
            + "during Setup but never activates by itself — without a reachable KMS host "
            + "the machine shows “Activate Windows”.",
        ProductKeyMode.Custom =>
            "A MAK or retail key of your own, written into the answer file. These activate "
            + "over the internet without a KMS host.",
        _ => string.Empty,
    };

    public static string Of(ActivationMode value) => value switch
    {
        ActivationMode.Automatic => "Automatic",
        ActivationMode.Kms => "Against a KMS host",
        ActivationMode.Skip => "Leave it alone",
        _ => value.ToString(),
    };

    public static string Detail(ActivationMode value) => value switch
    {
        ActivationMode.Automatic =>
            "Installs the OEM key from the PC's firmware if there is one, then activates "
            + "online. Clears the “Activate Windows” watermark without anyone "
            + "touching Settings.",
        ActivationMode.Kms => "Points the machine at your KMS host and activates against it.",
        ActivationMode.Skip => "Provisioning does not touch activation.",
        _ => string.Empty,
    };

    public static string Of(PartitionStyle value) =>
        value == PartitionStyle.Gpt ? "GPT (UEFI)" : "MBR (Legacy BIOS)";

    public static string Of(EndUserMode value) => value switch
    {
        EndUserMode.LeaveOobe => "Leave Windows OOBE to the user",
        EndUserMode.CreateLocalAccount => "Pre-create a local account",
        EndUserMode.PromptAtFirstBoot => "Prompt the technician on first boot",
        _ => value.ToString(),
    };

    public static string Of(JoinMode value) => value switch
    {
        JoinMode.Workgroup => "Workgroup",
        JoinMode.ActiveDirectory => "Active Directory domain",
        JoinMode.EntraAtOobe => "Entra ID / Intune at OOBE",
        _ => value.ToString(),
    };

    public static string Of(AppSource value) => value switch
    {
        AppSource.Winget => "winget",
        AppSource.Installer => "Bundled installer",
        AppSource.Script => "PowerShell",
        _ => value.ToString(),
    };

    public static string Of(PowerPlan value) => value switch
    {
        PowerPlan.Balanced => "Balanced",
        PowerPlan.HighPerformance => "High performance",
        PowerPlan.PowerSaver => "Power saver",
        _ => value.ToString(),
    };

    /// <summary>Built-in Windows power scheme GUIDs.</summary>
    public static string Guid(PowerPlan value) => value switch
    {
        PowerPlan.HighPerformance => "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c",
        PowerPlan.PowerSaver => "a1841308-3541-4fab-bc81-f71556f20b4a",
        _ => "381b4222-f694-41f0-9685-ff5bb260df2e",
    };

    public static string Of(LidAction value) => value switch
    {
        LidAction.DoNothing => "Do nothing",
        LidAction.Sleep => "Sleep",
        LidAction.Hibernate => "Hibernate",
        LidAction.ShutDown => "Shut down",
        _ => value.ToString(),
    };

    /// <summary>The LIDACTION value Windows stores. Fixed by Windows, not by us.</summary>
    public static int Index(LidAction value) => value switch
    {
        LidAction.DoNothing => 0,
        LidAction.Sleep => 1,
        LidAction.Hibernate => 2,
        LidAction.ShutDown => 3,
        _ => 1,
    };

    public static string Of(UpdatePolicy value) => value switch
    {
        UpdatePolicy.Automatic => "Install automatically",
        UpdatePolicy.NotifyBeforeDownload => "Notify before download",
        UpdatePolicy.DisableAutomaticRestart => "Auto-install, never auto-restart",
        _ => value.ToString(),
    };

    public static string Of(BitLockerMode value) => value switch
    {
        BitLockerMode.Off => "Off",
        BitLockerMode.TpmOnly => "Enable (TPM only)",
        BitLockerMode.TpmWithPin => "Enable (TPM + PIN)",
        _ => value.ToString(),
    };

    public static string Of(ScriptPhase value) => value switch
    {
        ScriptPhase.Specialize => "Setup (specialize)",
        ScriptPhase.Provision => "Provisioning",
        ScriptPhase.Finalize => "Finalize",
        _ => value.ToString(),
    };

    public static string Of(ImageOrigin value) => value switch
    {
        ImageOrigin.Microsoft => "Microsoft",
        ImageOrigin.Imported => "Imported",
        ImageOrigin.RemoteUrl => "Internal URL",
        _ => value.ToString(),
    };

    public static IReadOnlyList<T> All<T>() where T : struct, Enum => (T[])Enum.GetValues(typeof(T));
}
