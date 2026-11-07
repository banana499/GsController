<?xml version="1.0" encoding="UTF-8"?>
<!--
  Controlled heat transform for scripts\build-product.ps1 (heat -t).

  It is an identity transform everywhere except for the harvested component
  that carries gs-console.vbs as its keypath file. That single component
  gains a per-machine Start Menu ADVERTISED shortcut, so the entry points at
  the installed gs-console.vbs through the component's keypath and nothing
  is started automatically at install time. The shortcut lives directly in
  the standard ProgramMenuFolder (declared by installer\GsController.wxs for
  the foreign key only): NO new start-menu subdirectory is created, so no
  RemoveFolder/RemoveFile cleanup row and no HKCU registry keypath
  (ICE38/ICE64) is needed - the .lnk is removed with its component on
  uninstall. No registry entry, service, task or firewall change is created
  by this transform, and the shortcut serves both build profiles (the
  packaged gs-install-profile.json decides which page gs-console.ps1
  serves).
-->
<xsl:stylesheet version="1.0"
                xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
                xmlns:wix="http://schemas.microsoft.com/wix/2006/wi">
  <xsl:output method="xml" indent="yes" omit-xml-declaration="no" />
  <xsl:template match="@* | node()">
    <xsl:copy>
      <xsl:apply-templates select="@* | node()" />
    </xsl:copy>
  </xsl:template>
  <xsl:template match="wix:Component[wix:File[substring(@Source, string-length(@Source) - string-length('gs-console.vbs') + 1) = 'gs-console.vbs']]">
    <xsl:copy>
      <xsl:apply-templates select="@* | node()" />
      <!-- Per-machine Start Menu ADVERTISED shortcut: it points at the
           installed gs-console.vbs through this component's keypath file
           and nothing is started automatically at install time. It lives
           directly in the standard ProgramMenuFolder (declared by
           installer\GsController.wxs), so the .lnk is removed with this
           component on uninstall and no new profile directory - and thus
           no RemoveFile/RemoveFolder row and no HKCU registry keypath
           (ICE38/ICE64) - is ever needed. -->
      <wix:Shortcut Id="GsControllerStartMenuShortcut"
                    Directory="ProgramMenuFolder"
                    Name="GsController"
                    Advertise="yes" />
    </xsl:copy>
  </xsl:template>
</xsl:stylesheet>
