[CmdletBinding()]
param()
[pscustomobject]@{ Name = 'GsControllerSample'; Version = '0.1.1'; Ready = $true } | ConvertTo-Json -Compress
