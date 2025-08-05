# UserRemovalToolv1
This is a Powershell script that I wrote with the help of Copilot to offboard users in a Hybrid Microsoft 365 Environment. This script will remove the user from any groups and distribution lists on prem as well as in the cloud. The script will also remove their teams license as well as block their sign in. The script has been sanitized. 


************************ KNOWN ISSUES ***************************

There is a Connect-MgGraph error message that I believe is due to the graph module trying to remove users from on prem groups in the cloud. The script still functions as intended.
