xquery version "3.0";

(: Namespace for backup files :)
declare namespace exist = "http://exist.sourceforge.net/NS/exist";
declare option exist:serialize "method=hml media-type=text/html";

(: Backup in a zip if "action" = "Download" like ./bin/backup.sh -b /db/data -d data.zip :)
(: Restore from a zip if "action" = "Upload" like ./bin/backup.sh -r data.zip:)

(:~ Upload. Gives root collection from a zip :)
declare function local:getRootCol($zip) as xs:string {
  
  let $dataCb := function($path as xs:anyURI, $type as xs:string, $data as item()?, $param as item()*) as item ()?
  { $path }
  
  let $entryCb := function($path as xs:anyURI, $type as xs:string, $param as item()*) as xs:boolean
  { contains($path,"__contents__.xml") }
  
  let $paths := compression:unzip($zip, $entryCb, (), $dataCb, ())
  
  let $min := min($paths[. != ''])
  let $toks := tokenize($min, "/")
  let $colName := "/" || string-join(subsequence($toks, 1, count($toks) - 1), "/")

  return $colName
};

(:~ Upload. Set permissions on collection and ressources from "__contents__.xml"  :)
declare function local:setPermissionsFromContent($col) as xs:boolean? {
  
  (: Permissions on collection :)
  let $content := doc ($col||"/__contents__.xml")/exist:collection
  let $owner := $content/@owner 
  let $group := $content/@group
  let $mode := $content/@mode
  let $void := if($mode) then xmldb:chmod-collection($col, util:base-to-integer($mode, 8)) else()
  let $void := if($owner) then sm:chown(xs:anyURI ($col), $owner) else ()
  let $void := if ($group) then sm:chgrp(xs:anyURI ($col), $group) else ()

  (: Permissions on resources :)
  let $void := for $r in $content/exist:resource return 
    let $name := $r/@name 
    let $owner := $r/@owner 
    let $group := $r/@group
    let $mode := $r/@mode
    let $mode := util:base-to-integer($mode, 8)
    let $void := xmldb:chmod-resource($col, $name, $mode)
    let $void := sm:chown(xs:anyURI ($col||"/"||$name), $owner)
    let $void := sm:chgrp(xs:anyURI ($col||"/"||$name), $group)
    return ()
  
  (: Recurse :)
  let $void := for $c in xmldb:get-child-collections($col) return
    local:setPermissionsFromContent($col||"/"||$c)
    
  return ()
};

(:~ Upload. Filter entries from uploaded zip :)
declare function local:entry-filter($path as xs:anyURI, $type as xs:string, $param as item ()*) as xs:boolean {
  true()
};

(:~ Upload. Treat entries from uploaded zip :)
declare function local:entry-data($path as xs:anyURI, $type as xs:string, $data as item ()?, $param as item ()*) as item ()? {
  let $toks := tokenize($path, "/")
  let $colName := "/" || string-join(subsequence($toks, 1, count($toks) - 1), "/")
  let $docName := $toks[last()]
  
  (: Check that collections exists under $path, else creates them :)
  let $void :=for $i in reverse(1 to count($toks) - 1)
    let $colPath := "/" || string-join(subsequence($toks, 1, count($toks) - $i), "/")
    let $colPare := "/" || string-join(subsequence($toks, 1, count($toks) - $i - 1), "/")
    let $colName := $toks[count($toks) - $i]
    return
      if (xmldb:collection-available($colPath)) then ()
      else xmldb:create-collection($colPare, $colName)
      
  (: Write xml $data :)
  let $store := xmldb:store($colName, $docName, $data)
  return <div>{ $store }</div> 
};

(:~ Download. Add "__contents__.xml" for zip creation :)
declare function local:add__contents__($colName as xs:string) as item ()? {
  (: Permissions on collection :)
  let $p := sm:get-permissions($colName)/sm:permission 
  
  (: The collection :)
  let $data :=
  <collection xmlns="http://exist.sourceforge.net/NS/exist" name="{$colName}" owner="{$p/@owner}" group="{$p/@group}" 
    mode="{sm:mode-to-octal($p/@mode)}" created="{current-dateTime()}" version="1">
    <acl entries="0" version="1"/> 
    {
      (: Subcollections :)
      for $c in xmldb:get-child-collections($colName)
        return
        (: Recurse :)
        let $void := local:add__contents__($colName||'/'||$c) 
        (: Bug? without null="{$void}" there is no recursion :)
        return 
          <subcollection name="{ $c }" filename="{ $c }" null="{$void}"/>

      (: Resources at this level :)
      , for $r in xmldb:get-child-resources($colName)[. != __contents__.xml]
(:        where not($r = '__contents__.xml'):)
        let $p := sm:get-permissions(xs:anyURI($colName || '/' || $r))/sm:permission
        return
          <resource type="XMLResource" name="{$r}" owner="{$p/@owner}" group="{$p/@group}" mode="{sm:mode-to-octal($p/@mode)}"
            created="{xmldb:created($colName, $r)}" modified="{xmldb:last-modified($colName, $r)}" 
            filename="{$r}" mimetype="application/xml">
            <acl entries="0" version="1"/>
          </resource>
    }
  </collection>
  let $store := xmldb:store($colName, "__contents__.xml", $data)
  return ()
};

(:~ Download. Remove "__contents__.xml" after zip creation :)
declare function local:remove__contents__($colName as xs:string) as item()* {
  
  let $colNames := if (doc-available($colName || "/__contents__.xml")) 
    then xmldb:remove($colName, "__contents__.xml")
    else ()
    
  let $cols := for $c in xmldb:get-child-collections($colName)
    (: Recurse :)
    return local:remove__contents__($colName || '/' || $c)
    
  return () 
};

(: Download. "action" = "Download" :)
let $done :=
  if (request:get-parameter("action", ()) = "Download") then
    let $ouv := request:get-parameter("collection", "")
    let $collection := "/db/" || $ouv || "/"
    let $name := $ouv || ".zip"
    
    let $void := local:add__contents__($collection)
    let $zip := compression:zip(xs:anyURI($collection), true())
    let $void := local:remove__contents__($collection)
    
    return
    (
      response:set-header("Content-Disposition", concat("attachment; filename=", $name)),
      response:stream-binary($zip, "application/zip", $name)
    )
  else ()
        
(: Upload. "action" = "Upload" :) 
let $done := if (request:get-parameter("action", ()) = "Upload") then
  (: $zipFile gets data send by <input type="file" name="zipFile" :)
  let $zipFile :=  request:get-uploaded-file-data("zipFile")
  let $unzip :=
    try {
      let $rootCol := local:getRootCol($zipFile)
      let $void := if ( request:get-parameter("delete", ()) = "yes" and xmldb:collection-available($rootCol) ) 
        then ( xmldb:remove($rootCol) ) 
        else ()
        
      let $unzip := compression:unzip($zipFile, local:entry-filter # 3, (), local:entry-data # 4, ())
      let $void := local:setPermissionsFromContent($rootCol)
      let $void := local:remove__contents__($rootCol)
      
      return $unzip
    } catch * {
      util:log-system-out("Error:" || $err:description)
    }
  return $unzip
  else ()

(: Web page :)
let $page :=
<html>
 <head>
  <title>Backup</title>
  <link rel="stylesheet" href="css/bootstrap.min.css" type="text/css" media="print, projection, screen"/>
 </head>
 <body>
  <div class="container">

    <!-- Download -->
    <div class="page-header"><h1>Backup</h1></div>
    <form enctype="multipart/form-data" method="post" action="#" id="form0" class="form-inline" role="form">
      <input type="hidden" name="action" value="Download" />
      <label for="collection">Collection :&#160;</label>
      <select name="collection" title="collection" class="form-control">
      {
        for $col in xmldb:get-child-collections("/db")
        order by $col
        return
          (
            <option value="{ $col }">{ $col }</option>
            (: One level of subcollections :)
            , for $c in xmldb:get-child-collections($col)
             order by $c
            return <option value="{ $col||"/"||$c }">{ $col||"/"||$c }</option>
          )
      }
      </select>
      <input type="submit" class="btn btn-default"></input> <br/>
    </form>

    <!-- Upload -->
    <div class="page-header"><h1>Restore</h1></div>
    <form enctype="multipart/form-data" method="post" action="#" id="form" class="form-inline" role="form">
      <input type="hidden" name="action" value="Upload" />
      <label for="zipFile">Choose zip :&#160;</label>
      <input type="file" id="zipFile" name="zipFile" style="display:none"onchange="getElementById('form').submit();"/>
      <button class="btn btn-default" onclick="event.preventDefault();getElementById('zipFile').click();">Upload</button><br/>
      <input type="checkbox" id="deleteId" name="delete" value="yes"/>
      <label for="deleteId">Delete before</label>
    </form>

    <!-- Result -->
    {
      if ($done) 
      then (<div>Uploaded collections and files :</div>, $done) 
      else ()
    }

  </div>
 </body>
</html>

return $page
