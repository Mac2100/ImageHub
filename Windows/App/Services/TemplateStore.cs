using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using ImageHub.Models;
using ImageHub.Support;

namespace ImageHub.Services;

/// <summary>
/// Templates live as one JSON file each under %APPDATA%\ImageHub\Templates, so a
/// team can keep the folder in git or drop a colleague's template in by hand — and
/// a template exported from the macOS app opens here unchanged.
/// </summary>
public sealed class TemplateStore : Observable
{
    private readonly string _directory;
    private readonly List<DeploymentTemplate> _templates = new();

    /// <summary>
    /// IDs deleted in this session.
    ///
    /// The editor autosaves, and closing it flushes one last write. Deleting the
    /// template currently open therefore raced its own editor: the file was removed,
    /// the editor disappeared, its flush wrote the JSON straight back, and the
    /// deletion looked like it had done nothing. A save for a tombstoned ID is
    /// refused instead.
    /// </summary>
    private readonly HashSet<Guid> _tombstones = new();

    public TemplateStore(string? directory = null)
    {
        _directory = directory ?? AppPaths.Templates;
        Load();
    }

    public IReadOnlyList<DeploymentTemplate> Templates => _templates;

    public List<string> LoadWarnings { get; } = new();

    public string DirectoryPath => _directory;

    public event EventHandler? Changed;

    // MARK: - Loading

    public void Load()
    {
        _tombstones.Clear();
        LoadWarnings.Clear();
        _templates.Clear();
        Directory.CreateDirectory(_directory);

        string[] files;
        try { files = Directory.GetFiles(_directory, "*.json"); }
        catch (IOException) { files = Array.Empty<string>(); }

        foreach (string file in files)
        {
            try
            {
                DeploymentTemplate? template = Json.Deserialize<DeploymentTemplate>(File.ReadAllText(file));
                if (template is null)
                {
                    LoadWarnings.Add($"Couldn't read {Path.GetFileName(file)}: it isn't a template.");
                    continue;
                }
                // A template keeps the package IDs it was created with, so a catalog
                // correction has to be applied on the way in or it never reaches one.
                AppCatalog.CorrectRenames(template);
                AppCatalog.MigrateOffice(template);
                _templates.Add(template);
            }
            catch (Exception error)
            {
                LoadWarnings.Add($"Couldn't read {Path.GetFileName(file)}: {error.Message}");
            }
        }

        if (_templates.Count == 0 && files.Length == 0 && !Settings.Current.DidSeedStarterTemplates)
        {
            _templates.AddRange(DeploymentTemplate.StarterPack());
            foreach (DeploymentTemplate template in _templates) { TryPersist(template); }
            Settings.Current.DidSeedStarterTemplates = true;
            Settings.Current.Save();
        }

        Sort();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void Sort() =>
        _templates.Sort((a, b) => string.Compare(a.Name, b.Name, StringComparison.CurrentCultureIgnoreCase));

    // MARK: - Mutation

    public DeploymentTemplate? Template(Guid id) => _templates.FirstOrDefault(t => t.Id == id);

    public bool Save(DeploymentTemplate template)
    {
        if (_tombstones.Contains(template.Id)) { return false; }
        template.UpdatedAt = DateTime.UtcNow;
        if (!TryPersist(template, out string? error))
        {
            Notifier.Banner("Couldn't save template", error ?? string.Empty, BannerKind.Error);
            return false;
        }
        if (!_templates.Any(t => t.Id == template.Id)) { _templates.Add(template); }
        Sort();
        Changed?.Invoke(this, EventArgs.Empty);
        return true;
    }

    public void Delete(DeploymentTemplate template)
    {
        _tombstones.Add(template.Id);
        try { File.Delete(PathFor(template.Id)); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        SecretStore.DeleteAll(template.Id);
        _templates.RemoveAll(t => t.Id == template.Id);
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public DeploymentTemplate Duplicate(DeploymentTemplate template)
    {
        DeploymentTemplate copy = template.DeepCopy();
        Guid original = template.Id;
        copy.Id = Guid.NewGuid();
        copy.Name = UniqueName(template.Name);
        copy.CreatedAt = DateTime.UtcNow;
        copy.UpdatedAt = DateTime.UtcNow;
        // Fresh identities for the child objects too, so editing one copy's app list
        // can never be mistaken for the other's.
        foreach (AppSelection app in copy.Apps) { app.Id = Guid.NewGuid(); }
        foreach (CustomScript script in copy.Scripts) { script.Id = Guid.NewGuid(); }
        foreach (RegistryTweak tweak in copy.System.RegistryTweaks) { tweak.Id = Guid.NewGuid(); }

        // Secrets are per-template; carry them across so the copy is immediately
        // buildable rather than reporting a missing admin password.
        SecretStore.CopyAll(original, copy.Id);
        Save(copy);
        return copy;
    }

    public DeploymentTemplate NewTemplate()
    {
        var template = new DeploymentTemplate { Name = UniqueName("New Template") };
        Save(template);
        return template;
    }

    private string UniqueName(string baseName)
    {
        var existing = new HashSet<string>(_templates.Select(t => t.Name), StringComparer.CurrentCulture);
        if (!existing.Contains(baseName)) { return baseName; }
        int index = 2;
        while (existing.Contains($"{baseName} {index}")) { index++; }
        return $"{baseName} {index}";
    }

    // MARK: - Import / export

    /// <summary>
    /// Reads a template from an arbitrary file, giving it a fresh identity so it never
    /// collides with one already in the library.
    /// </summary>
    public DeploymentTemplate Import(string path)
    {
        DeploymentTemplate template = Json.Deserialize<DeploymentTemplate>(File.ReadAllText(path))
            ?? throw new InvalidDataException("That file isn't an ImageHub template.");
        AppCatalog.CorrectRenames(template);
        AppCatalog.MigrateOffice(template);
        if (_templates.Any(t => t.Id == template.Id) || _tombstones.Contains(template.Id))
        {
            template.Id = Guid.NewGuid();
            template.Name = UniqueName(template.Name);
        }
        Save(template);
        return template;
    }

    public void Export(DeploymentTemplate template, string path) =>
        File.WriteAllText(path, Json.Serialize(template));

    // MARK: - Disk

    private string PathFor(Guid id) =>
        Path.Combine(_directory, id.ToString("D").ToUpperInvariant() + ".json");

    private bool TryPersist(DeploymentTemplate template) => TryPersist(template, out _);

    private bool TryPersist(DeploymentTemplate template, out string? error)
    {
        error = null;
        try
        {
            Directory.CreateDirectory(_directory);
            string path = PathFor(template.Id);
            string temporary = path + ".tmp";
            File.WriteAllText(temporary, Json.Serialize(template));
            File.Move(temporary, path, overwrite: true);
            return true;
        }
        catch (Exception failure)
        {
            error = failure.Message;
            return false;
        }
    }
}
