function addNodes(iterator, path){
  var text = "";
  path = path.replace(/\/+$/, "") + "/"; // unify the path
  try {
	var thisNode = iterator.iterateNext();
	while (thisNode) {
	  var blobName = thisNode.getElementsByTagName("Name")[0].textContent;
	  if (!blobName.endsWith('azure_storage_index.html')){
		  var absName = "/" + blobName;
		  var newPath = path + thisNode.getElementsByTagName("Name")[0].textContent;
		  text += '<tr><td><a href="' + absName + '">' + absName.replace(path, '') + '</a></td></tr>';
	  }
	  
	  thisNode = iterator.iterateNext();
	}
  }
  catch (e) {
    alert( 'Error: Document tree modified during iteration ' + e );
  }
  
  return text;
}

function listblobs()
{
    var endpoint = "https://sonicstoragepublic20.blob.core.windows.net";
    var path = window.location.pathname;
    var URL = endpoint + "/$web?restype=directory&comp=list&delimiter=/&prefix=" + path + "/";
    var xmlhttp = new XMLHttpRequest();
	xmlhttp.overrideMimeType('text/xml');
    xmlhttp.open("GET", URL, false);
    xmlhttp.send();
	var xml = xmlhttp.responseXML;
	//console.log( xmlhttp.responseText);
	var innerHTML = "<h1>Index of " + path + "</h1><table>";
	var blobPrefixes = xml.evaluate('//EnumerationResults/Blobs/BlobPrefix', xml, null, XPathResult.ORDERED_NODE_ITERATOR_TYPE, null);
	var blobs = xml.evaluate('//EnumerationResults/Blobs/Blob', xml, null, XPathResult.ORDERED_NODE_ITERATOR_TYPE, null);
	innerHTML += addNodes(blobPrefixes, path);
	innerHTML += addNodes(blobs, path);
	innerHTML += "</table>";
	document.getElementById("div").innerHTML = innerHTML;
}
