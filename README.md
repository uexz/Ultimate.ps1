<img width="662" height="187" alt="image" src="https://github.com/user-attachments/assets/60476d3c-2320-499c-86ae-5526928071b1" />

# Ultimate.ps1
Ultimate.ps1 is a user-friendly tool for debloating and optimizing the Windows experience.
It's designed for users needing a minimal, responsive OS environment.

#Features
Ultimate.ps1 offers wild number of sections that the user can choose from:
1. Defender & Security: Disables and forces policies on Windows Defender and Security. This section isn't recommended for everyday use because it leaves major security risks on your machine.

2. Windows Update: Disables Windows updates, stops wuauserv service, and forces policies on updates. This section is NOT recommended for regular users.

3. Microsoft Edge Removal: Removes the Microsoft Edge browser.

4. Registry Tweaks: This section applies 300+ registry tweaks; it includes:
Disabling telemetry, diagnostics, and data collection

Disabling Cortana, Bing search, and web search

Disabling telemetry and bloat in Edge, Brave, and Firefox

Optimizes System profile Key by changing SystemResponsiveness, tweaking the priorities, and many others

5. Host File: Updates host file to block Microsoft spying and data collection; it also backs up the original host file

6. USB Power: Disables power saving on every USB root for performance

7. System Services: Disables and stops unnecessary Windows services ( includes: defragsvc, DeviceAssociationService, BcastDVRUserService, BITS,
     sysmain, WpnService, WpnUserService, MozillaMaintenance,
    CDPSvc, CDPUserSvc, dot3svc, DPS, iphlpsvc, defragsvc,
    diagnosticshub.standardcollector.service, diagsvc, DiagTrack, DoSvc,
     lmhosts, diagsvc, DiagTrack, dmwappushservice,
    OneSyncSvc, PrintNotify, PrintWorkflowUserSvc, RasMan,
    Rmsvc, SensorDataService, SensorService, SharedAccess,
    lfsvc, Spooler, TokenBroker, LanmanWorkstation",
	  rdbss, KSecPkg, WSAIFabricSvc.)
	
8. Scheduled Tasks: Disables unnecessary Windows tasks that include Telemetry and data collection

9. BCDEdit Configuration: Tweaks and changes BCD, AKA Boot Configuration Data settings.

10. Power Plan Options: Disables hibernation, Imports an ultimate-performance power plan, and sets pagefile size based on your RAM

11. AppX Packages Removal: Removes a bunch of unnecessary UWP apps that are not used

12. System Apps Removal:

13. OneDrive Removal: Uninstalls and removes OneDrive

14. Microsoft Teams Removal: Uninstalls and removes Microsoft Teams app

15. Xbox Removal: Uninstalls and removes every Xbox component. THIS SECTION IS OPTIONAL

16. Component Cleanup: Runs DISM cleanup, Disables Reserved Storage, flushes Windows Update cache, and disables indexing 

17. Drivers cleanup: Removes and cleans unnecessary/orphaned drivers that have never been used by the System

18. Network Tweaks: Applies network tweaks, Disables power saving on network adapters, and disables IPv6

19. Windows Optional Features: Disables unnecessary Windows optional features including ("Recall", "HyperV", "Microsoft-Hyper-V-All", "LegacyComponents", "DirectPlay",
    MediaPlayback, WindowsMediaPlayer, Printing-Foundation-Features,
    Printing-Foundation-InternetPrinting-Client, Printing-XPSServices-Features,
    FaxServicesClientPackage, WorkFolders-Client, Microsoft-Windows-Subsystem-Linux,
    VirtualMachinePlatform, Windows-Identity-Foundation, IIS-WebServerRole-Package,
    Msmq-Container, TFTP, TelnetClient, SmbDirect.)

20. Cursors scheme: Download and apply a cool No-tail cursor scheme

# REQUIREMENTS
Windows 10 and higher ( tested on Windows 10 and Windows 11)
POWERSHELL CORE 7 and higher (https://github.com/powershell/powershell)

# Script Not Working?
Try executing this command first before starting the script: "Set-ExecutionPolicy Bypass -Scope LocalMachine -Force"

🆘 Support / Help
If you have any issues or have questions about Ultimate.ps1, feel free to DM me on Discord:

Discord: @uexz_
