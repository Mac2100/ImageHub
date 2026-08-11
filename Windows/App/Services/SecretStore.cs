using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using ImageHub.Models;
using ImageHub.Support;

namespace ImageHub.Services;

/// <summary>Distinct secret slots a template can own.</summary>
public enum SecretSlot
{
    AdminPassword,
    UserPassword,
    DomainPassword,
    ProductKey,
    WifiPassword,
}

/// <summary>Where template secrets are kept.</summary>
public enum SecretBackend
{
    /// <summary>
    /// A file encrypted with the Windows Data Protection API, tied to this user
    /// account on this machine. The counterpart of the macOS Keychain, without the
    /// prompt that an ad-hoc signature causes there.
    /// </summary>
    Dpapi,

    /// <summary>
    /// One entry per secret in Windows Credential Manager, so they can be audited and
    /// removed from Control Panel like any other saved credential.
    /// </summary>
    CredentialManager,
}

/// <summary>
/// Storage for template secrets: local-admin password, end-user password, domain
/// join credentials, product key, Wi-Fi passphrase.
///
/// Templates never contain them, which is what makes a template safe to export and
/// commit. They leave here in exactly one place — writing a drive — because
/// Windows Setup reads account passwords from autounattend.xml in clear text.
/// That is how the format works, so a finished USB drive is a credential.
///
/// Read once and cached in memory: DeploymentTemplate.Issues asks whether a
/// password exists, and that runs whenever the editor recomputes, so it must not
/// hit the store every time.
/// </summary>
public static class SecretStore
{
    private const string ServiceName = "ImageHub";
    private const string CredentialPrefix = "ImageHub/";

    private static readonly object Gate = new();
    private static Dictionary<string, string>? _cache;

    public static string Label(SecretSlot slot) => slot switch
    {
        SecretSlot.AdminPassword => "Admin password",
        SecretSlot.UserPassword => "User password",
        SecretSlot.DomainPassword => "Domain join password",
        SecretSlot.ProductKey => "Product key",
        SecretSlot.WifiPassword => "Wi-Fi password",
        _ => slot.ToString(),
    };

    public static string Label(SecretBackend backend) => backend switch
    {
        SecretBackend.Dpapi => "Windows Data Protection (encrypted file)",
        SecretBackend.CredentialManager => "Windows Credential Manager",
        _ => backend.ToString(),
    };

    public static string Help(SecretBackend backend) => backend switch
    {
        SecretBackend.Dpapi =>
            "Encrypted by Windows with a key tied to your account on this PC, in "
            + "ImageHub's own folder. Nothing else signed in as anyone else can read it, "
            + "and there is no prompt.",
        SecretBackend.CredentialManager =>
            "One entry per secret under Control Panel → Credential Manager → Windows "
            + "Credentials, so they can be reviewed and removed with everything else "
            + "Windows keeps for you. Same protection, more visible.",
        _ => string.Empty,
    };

    public static SecretBackend Backend
    {
        get => Settings.Current.SecretBackend;
        set
        {
            if (value == Settings.Current.SecretBackend) { return; }
            // Read everything through the old backend first, then write it all back
            // through the new one, so switching storage never loses a password.
            Dictionary<string, string> existing = All();
            Settings.Current.SecretBackend = value;
            Settings.Current.Save();
            lock (Gate) { _cache = existing; }
            Write(existing);
        }
    }

    private static string Key(Guid templateId, SecretSlot slot) =>
        templateId.ToString("D").ToUpperInvariant() + "." + RawSlot(slot);

    /// <summary>
    /// The slot names the macOS app uses. They only matter inside this store, but
    /// keeping them identical means a future export/import of secrets between
    /// platforms has nothing to translate.
    /// </summary>
    private static string RawSlot(SecretSlot slot) => slot switch
    {
        SecretSlot.AdminPassword => "adminPassword",
        SecretSlot.UserPassword => "userPassword",
        SecretSlot.DomainPassword => "domainPassword",
        SecretSlot.ProductKey => "productKey",
        SecretSlot.WifiPassword => "wifiPassword",
        _ => slot.ToString(),
    };

    // MARK: - Public API

    public static string? Get(Guid templateId, SecretSlot slot)
    {
        All().TryGetValue(Key(templateId, slot), out string? value);
        return string.IsNullOrEmpty(value) ? null : value;
    }

    public static bool Has(Guid templateId, SecretSlot slot) => Get(templateId, slot) is not null;

    public static bool Set(string secret, Guid templateId, SecretSlot slot)
    {
        Dictionary<string, string> secrets = new(All());
        string key = Key(templateId, slot);
        if (string.IsNullOrEmpty(secret)) { secrets.Remove(key); }
        else { secrets[key] = secret; }
        lock (Gate) { _cache = secrets; }
        return Write(secrets);
    }

    public static void Delete(Guid templateId, SecretSlot slot) => Set(string.Empty, templateId, slot);

    /// <summary>Called when a template is deleted so no orphaned secrets are left behind.</summary>
    public static void DeleteAll(Guid templateId)
    {
        Dictionary<string, string> secrets = new(All());
        foreach (SecretSlot slot in Labels.All<SecretSlot>())
        {
            secrets.Remove(Key(templateId, slot));
        }
        lock (Gate) { _cache = secrets; }
        Write(secrets);
    }

    /// <summary>Copies every secret from one template to another, for Duplicate.</summary>
    public static void CopyAll(Guid from, Guid to)
    {
        foreach (SecretSlot slot in Labels.All<SecretSlot>())
        {
            string? secret = Get(from, slot);
            if (secret is not null) { Set(secret, to, slot); }
        }
    }

    public static void ForgetCache()
    {
        lock (Gate) { _cache = null; }
    }

    // MARK: - Backing store

    private static Dictionary<string, string> All()
    {
        lock (Gate)
        {
            if (_cache is not null) { return _cache; }
        }
        Dictionary<string, string> loaded = Read();
        lock (Gate) { _cache = loaded; }
        return loaded;
    }

    private static Dictionary<string, string> Read()
    {
        try
        {
            return Backend == SecretBackend.CredentialManager ? ReadCredentials() : ReadDpapiFile();
        }
        catch (Exception)
        {
            return new Dictionary<string, string>();
        }
    }

    private static bool Write(Dictionary<string, string> secrets)
    {
        try
        {
            return Backend == SecretBackend.CredentialManager
                ? WriteCredentials(secrets)
                : WriteDpapiFile(secrets);
        }
        catch (Exception)
        {
            return false;
        }
    }

    // MARK: - DPAPI file

    private static Dictionary<string, string> ReadDpapiFile()
    {
        string path = AppPaths.SecretsFile;
        if (!File.Exists(path)) { return new Dictionary<string, string>(); }
        byte[] encrypted = File.ReadAllBytes(path);
        byte[]? plain = Dpapi.Unprotect(encrypted);
        if (plain is null) { return new Dictionary<string, string>(); }
        string json = Encoding.UTF8.GetString(plain);
        Array.Clear(plain, 0, plain.Length);
        return Json.Deserialize<Dictionary<string, string>>(json) ?? new Dictionary<string, string>();
    }

    private static bool WriteDpapiFile(Dictionary<string, string> secrets)
    {
        byte[] plain = Encoding.UTF8.GetBytes(Json.Serialize(secrets));
        try
        {
            byte[]? encrypted = Dpapi.Protect(plain);
            if (encrypted is null) { return false; }
            string path = AppPaths.SecretsFile;
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            // Written through a temporary file so an interrupted write cannot leave a
            // truncated blob that decrypts to nothing.
            string temporary = path + ".tmp";
            File.WriteAllBytes(temporary, encrypted);
            File.Move(temporary, path, overwrite: true);
            return true;
        }
        finally
        {
            Array.Clear(plain, 0, plain.Length);
        }
    }

    // MARK: - Credential Manager

    private static Dictionary<string, string> ReadCredentials()
    {
        var secrets = new Dictionary<string, string>();
        foreach ((string target, string value) in NativeCredentials.Enumerate(CredentialPrefix + "*"))
        {
            if (!target.StartsWith(CredentialPrefix, StringComparison.OrdinalIgnoreCase)) { continue; }
            secrets[target.Substring(CredentialPrefix.Length)] = value;
        }
        return secrets;
    }

    private static bool WriteCredentials(Dictionary<string, string> secrets)
    {
        bool ok = true;
        // Remove anything that is no longer wanted, then write what is.
        foreach ((string target, string _) in NativeCredentials.Enumerate(CredentialPrefix + "*"))
        {
            string key = target.StartsWith(CredentialPrefix, StringComparison.OrdinalIgnoreCase)
                ? target.Substring(CredentialPrefix.Length)
                : target;
            if (!secrets.ContainsKey(key)) { NativeCredentials.Delete(target); }
        }
        foreach ((string key, string value) in secrets)
        {
            if (!NativeCredentials.Write(CredentialPrefix + key, ServiceName, value)) { ok = false; }
        }
        return ok;
    }
}

/// <summary>Windows Data Protection, user scope. No prompt, no key to manage.</summary>
internal static class Dpapi
{
    private const int CryptProtectUiForbidden = 0x1;

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob
    {
        public int Size;
        public IntPtr Data;
    }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CryptProtectData(
        ref DataBlob input, string? description, IntPtr entropy, IntPtr reserved,
        IntPtr prompt, int flags, ref DataBlob output);

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CryptUnprotectData(
        ref DataBlob input, IntPtr description, IntPtr entropy, IntPtr reserved,
        IntPtr prompt, int flags, ref DataBlob output);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr handle);

    public static byte[]? Protect(byte[] plain) =>
        Transform(plain, encrypt: true);

    public static byte[]? Unprotect(byte[] encrypted) =>
        Transform(encrypted, encrypt: false);

    private static byte[]? Transform(byte[] source, bool encrypt)
    {
        var input = new DataBlob();
        var output = new DataBlob();
        try
        {
            input.Size = source.Length;
            input.Data = Marshal.AllocHGlobal(Math.Max(1, source.Length));
            Marshal.Copy(source, 0, input.Data, source.Length);

            bool ok = encrypt
                ? CryptProtectData(ref input, "ImageHub template secrets", IntPtr.Zero,
                    IntPtr.Zero, IntPtr.Zero, CryptProtectUiForbidden, ref output)
                : CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero,
                    IntPtr.Zero, IntPtr.Zero, CryptProtectUiForbidden, ref output);
            if (!ok || output.Data == IntPtr.Zero) { return null; }

            var result = new byte[output.Size];
            Marshal.Copy(output.Data, result, 0, output.Size);
            return result;
        }
        catch (Exception)
        {
            return null;
        }
        finally
        {
            if (input.Data != IntPtr.Zero) { Marshal.FreeHGlobal(input.Data); }
            if (output.Data != IntPtr.Zero) { LocalFree(output.Data); }
        }
    }
}

/// <summary>The CredRead/CredWrite/CredEnumerate trio, for the Credential Manager backend.</summary>
internal static class NativeCredentials
{
    private const uint TypeGeneric = 1;
    private const uint PersistLocalMachine = 2;

    [StructLayout(LayoutKind.Sequential)]
    private struct Credential
    {
        public uint Flags;
        public uint Type;
        public IntPtr TargetName;
        public IntPtr Comment;
        public long LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public IntPtr TargetAlias;
        public IntPtr UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWrite(ref Credential credential, uint flags);

    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDelete(string target, uint type, uint flags);

    [DllImport("advapi32.dll", EntryPoint = "CredEnumerateW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredEnumerate(string? filter, uint flags, out uint count, out IntPtr credentials);

    [DllImport("advapi32.dll", EntryPoint = "CredFree")]
    private static extern void CredFree(IntPtr buffer);

    public static bool Write(string target, string userName, string secret)
    {
        byte[] blob = Encoding.Unicode.GetBytes(secret);
        IntPtr targetPtr = IntPtr.Zero;
        IntPtr userPtr = IntPtr.Zero;
        IntPtr blobPtr = IntPtr.Zero;
        try
        {
            targetPtr = Marshal.StringToCoTaskMemUni(target);
            userPtr = Marshal.StringToCoTaskMemUni(userName);
            blobPtr = Marshal.AllocCoTaskMem(Math.Max(1, blob.Length));
            Marshal.Copy(blob, 0, blobPtr, blob.Length);

            var credential = new Credential
            {
                Type = TypeGeneric,
                TargetName = targetPtr,
                CredentialBlobSize = (uint)blob.Length,
                CredentialBlob = blobPtr,
                Persist = PersistLocalMachine,
                UserName = userPtr,
            };
            return CredWrite(ref credential, 0);
        }
        catch (Exception)
        {
            return false;
        }
        finally
        {
            if (targetPtr != IntPtr.Zero) { Marshal.FreeCoTaskMem(targetPtr); }
            if (userPtr != IntPtr.Zero) { Marshal.FreeCoTaskMem(userPtr); }
            if (blobPtr != IntPtr.Zero) { Marshal.FreeCoTaskMem(blobPtr); }
            Array.Clear(blob, 0, blob.Length);
        }
    }

    public static void Delete(string target)
    {
        try { CredDelete(target, TypeGeneric, 0); } catch (Exception) { }
    }

    public static List<(string Target, string Secret)> Enumerate(string filter)
    {
        var found = new List<(string, string)>();
        IntPtr buffer = IntPtr.Zero;
        try
        {
            if (!CredEnumerate(filter, 0, out uint count, out buffer)) { return found; }
            for (uint i = 0; i < count; i++)
            {
                IntPtr entry = Marshal.ReadIntPtr(buffer, (int)(i * (uint)IntPtr.Size));
                if (entry == IntPtr.Zero) { continue; }
                var credential = Marshal.PtrToStructure<Credential>(entry);
                string? target = credential.TargetName == IntPtr.Zero
                    ? null : Marshal.PtrToStringUni(credential.TargetName);
                if (target is null) { continue; }
                string secret = string.Empty;
                if (credential.CredentialBlob != IntPtr.Zero && credential.CredentialBlobSize > 0)
                {
                    secret = Marshal.PtrToStringUni(
                        credential.CredentialBlob, (int)(credential.CredentialBlobSize / 2)) ?? string.Empty;
                }
                found.Add((target, secret));
            }
        }
        catch (Exception)
        {
        }
        finally
        {
            if (buffer != IntPtr.Zero) { CredFree(buffer); }
        }
        return found;
    }
}
