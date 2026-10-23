// One-time migration for versions released before semantic bundle detection.
// These signatures are never used to patch a new Steam version.
static const struct { const char *original; const char *hidden; } legacy_patches[] = {
    { "(0,e.jsx)(Ct,{classNames:(0,M.A)(V().SuperimposedGridItems,V().Visible,V().CloudStatusSyncFail),force_icon:!0,strTooltip:ye,on_click:F,icon:(0,e.jsx)(B.CloudSync,{...$t}),label:(0,Y.we)(\"#AppDetails_SectionTitle_CloudStatus\"),children:(0,e.jsx)(ae.eJ,{className:V().ClickablePlayBarItem,children:zt(Yt,qt)})})", "null/*macsteam-cloud-error*/" },
    { "return(0,e.jsxs)(m.Z,{focusable:_,className:(0,M.A)(_&&V().CloudSyncProblem,V().CloudStatusRow),", "return _?null:(0,e.jsxs)(m.Z,{className:(0,M.A)(_&&V().CloudSyncProblem,V().CloudStatusRow)," },
    { "function H(se){switch(se.display_status){case D.Ul.hN:case D.Ul.c7:case D.Ul.js:return!0}return!1}", "function H(se){switch(se.display_status){case D.Ul.js:return!0}return!1}" },
    { "case D.Ul.hN:case D.Ul.c7:Oe=(0,e.jsx)(ae,{appName:ee,lang:De,status:(0,b.Bb)(V.display_status,se.item.most_available_per_client_data?.clientid,!0)});break", "case D.Ul.hN:case D.Ul.c7:break" },
    { "ShowCloudIssueDialog(_e,xe,Ue,Re,mt){if(mt||(mt=window),xe===\"cloudconflict\"){(0,n.TE)({bOnAppLaunch:!0,appid:_e,onCancel:Ue,keepLocal:()=>Re(\"KeepLocal\"),keepRemote:()=>Re(\"KeepRemote\"),onOK:()=>Re(\"IgnoreCloud\")},mt);return}else if(xe===\"syncfailed\"){(0,n.zI)({appid:_e,onCancel:Ue,onOK:()=>Re(\"IgnoreCloud\"),bOnAppLaunch:!0},mt);return}else if(xe===\"pendingcloudsessions\"){(0,n.aj)({appid:_e,onCancel:Ue,onOK:()=>Re(\"IgnorePendingCloudSessions\")},mt);return}else{Oe.Error(\"Unknown request for synchronizing cloud: \",xe),Re(xe);return}}", "ShowCloudIssueDialog(_e,xe,Ue,Re,mt){if(xe===\"cloudconflict\"||xe===\"syncfailed\"){Re(\"IgnoreCloud\");return}if(xe===\"pendingcloudsessions\"){Re(\"IgnorePendingCloudSessions\");return}Re(xe)}" },
    { "proto:l.W9,fnTray:zt,showToast:!0,sound:L.PN.ToastMisc,", "proto:l.W9,fnTray:null,showToast:!1,playSound:!1," },
    { "proto:l.A_,fnTray:zt,showToast:!0,sound:L.PN.ToastMisc,", "proto:l.A_,fnTray:null,showToast:!1,playSound:!1," },
};
