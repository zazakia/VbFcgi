VERSION 1.0 CLASS
BEGIN
  MultiUse = -1  'True
  Persistable = 0  'NotPersistable
  DataBindingBehavior = 0  'vbNone
  DataSourceBehavior  = 0  'vbNone
  MTSTransactionMode  = 0  'NotAnMTSObject
END
Attribute VB_Name = "CBuilderTemplate"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = False
Attribute VB_PredeclaredId = False
Attribute VB_Exposed = True
Option Explicit

' Copyright (c) 2017 Jason Peter Brown <jason@bitspaces.com>
'
' MIT License
'
' Permission is hereby granted, free of charge, to any person obtaining a copy
' of this software and associated documentation files (the "Software"), to deal
' in the Software without restriction, including without limitation the rights
' to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
' copies of the Software, and to permit persons to whom the Software is
' furnished to do so, subject to the following conditions:
'
' The above copyright notice and this permission notice shall be included in all
' copies or substantial portions of the Software.
'
' THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
' IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
' FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
' AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
' LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
' OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
' SOFTWARE.

' -------------------------------------------------------------------------------
' PURPOSE
' -------------------------------------------------------------------------------
'
' This class helps you take partial HTML documents with a .VBML file extension
' from the file system and substitute special "tags" in the document with
' dynamic HTML generated by your FCGI application.
' Once all tag>html translations have been performed, the completed HTML document
' will be sent downstream to the browser.
'
' The convenience of this approach is that you can create & modify the HTML
' documents in your favourite editor. Updates will appear live without
' requiring you to recompile your FCGI application DLL (provided you haven't
' created new unhandled tags) nor requiring you restart your web server.
'
' -------------------------------------------------------------------------------
' USAGE
' -------------------------------------------------------------------------------
'
' Create VBML files:
'
' First, you will need to create .VBML files and store them on a drive that
' your FCGI application has access to. I recommend a \vbml\ folder
' (or sub folders of that folder) that is in the same folder as
' your FCGI application DLL.
'
' VBML files are regular HTML/text files that include special tags where you want
' dynamic data that is generated by your FCGI application to appear.
' By default tags are identified by opening "[[" and closing "]]" characters,
' but this is customizable.
'
' Tags should only include letters A-Z, numbers 0-9, underscore, space, and dash
' characters.
' Tags should not contain the opening or closing tag strings.
' Sequences of 2 or more spaces in a row in a tag name will be converted to a single space
' Leading and trailing spaces will be trimed.
' Tags will always be sent to your FCGI application in lower case.
'
' So [[ My Tag]] is the same as [[MY     TAG]] and [[my tag]]
'
' Parse VBML files:
'
' In your FCGI application's ProcessRequest method, you will be passed a
' CFcgiRepsonse object (po_FcgiResponse).
'
' If your FCGI application determines that it should parse a .VBML file,
' and send it to the browser, it should set a module level CBuilderTemplate variable
' with the "WithEvents" keyword specified to the return value of a call to
' po_FcgiResponse.Builder(builder_Template). e.g.:
'
' Private WithEvents mo_Template As VbFcgiLib.CBuilderTemplate
'
' Public Sub IFcgiApp_ProcessRequest(po_Request As CFcgiRequest, po_Response As CFcgiResponse)
'   Set mo_Template = po_FcgiResponse.Builder(builder_Template)
'
'   ' Parse the VBML file for tags
'   mo_Template.ParseFile pathBin & "vbml" & po_Request.Fcgi.Params.ValueByEnum(stdparam_PathInfo)
'
'   ' Signal completion to downstream app server and convert content to desired encoding
'   mo_Template.Finish contentencoding_Utf8
' End Sub
'
' You should then perform all your tag to data conversions in the CBuilderTemplate FoundTag
' Event. E.g.:
'
' Private Sub mo_Vbml_FoundTag(ByVal p_Tag As String, po_Replacement As VbFcgiLib.CWebStringTemplate, ByRef p_DoNotReplace As Boolean)
'    Select Case p_Tag
'    Case "current_date"   ' This is the unique tag name found in your VBML document
'       po_Replacement = Format$(Now, "Long Date")   ' This is the text that you want to replace the tag with
'    End Select
' End SUb
'
' Note that the FoundTag event receives a VbFcgiLib.CWebStringTemplate object (see that class for more info).
' The default property is .Content so you can just assign a string to po_Replacement for simple replacements.
' However, for more complex replacements, you can access the HTML helper functions of the CWebStringTemplate class.

Implements VbFcgiLib.IBuilder

Public Event FoundTag(ByVal p_Tag As String, po_Replacement As VbFcgiLib.CWebStringTemplate, ByRef p_DoNotReplace As Boolean)
Public Event Finished()

Private WithEvents mo_HttpHeader As VbFcgiLib.CHttpHeader
Attribute mo_HttpHeader.VB_VarHelpID = -1

Private m_Finished As Boolean
Private m_Length As Long
Private m_ContentEncoding As VbFcgiLib.e_ContentEncoding
Private ma_Content() As Byte
Private m_Content As String

Private m_OpenTag As String
Private m_CloseTag As String

Public Sub ParseFile(ByVal p_FilePathOrContent As String, Optional ByVal p_CodePage As vbRichClient5.MSCodePages = 0)
   ' This method will slurp a file and search for tags as identified by the m_OpenTag and m_CloseTag variables.
   ' By default open and close tag identifiers are "[[" and "]]"
   ' When found, the content in between the tags will be extracted and whitespace will be flattened a trimmed.
   ' A tag cache will then be searched for replacement text. If found, that will be used.
   ' If no cached replacement text is found, the FoundTag event will be raised, giving the host a chance to supply replacement text.
   ' This replacement text can be optionally cached to prevent future events for the same tag
   
   Dim l_File As String
   Dim l_Utf16NoBom As Boolean
   Dim l_TagStart As Long
   Dim l_TagEnd As Long
   Dim l_Tag As String
   Dim l_SkipReplace As Boolean
   Dim l_SkipRescan As Boolean
   Dim l_SkipCache As Boolean
   Dim l_EncodeEntities As Boolean
   Dim l_ReplaceWith As String
   Dim lo_Cache As vbRichClient5.cCollection
   Dim lo_StringBuilder As vbRichClient5.cStringBuilder
   Dim lo_SkipTags As vbRichClient5.cCollection
   Dim l_NewContentEnd As Long
   Dim lo_StringTemplate As VbFcgiLib.CWebStringTemplate
   
   ' 0 = Recommended default code page, assume UTF-8
   If p_CodePage = 0 Then p_CodePage = CP_UTF8
   
   Select Case p_CodePage
   Case 1200   '    ' Codepage 1200 assume RAW UTF16LE/VB String
      l_Utf16NoBom = True
      p_CodePage = 0
   
   Case 1201   ' UTF16BE
      ' Force BOM detection in CFso.ReadTextContent
      l_Utf16NoBom = False
      p_CodePage = 0
      
   End Select
   
   If Not libFso.FileExists(p_FilePathOrContent) Then
      ' Check if we have an missing file, or if we should use pass value as content
      Select Case Mid$(p_FilePathOrContent, 2, 1)
      Case ":", "\"
         Select Case Mid$(p_FilePathOrContent, 1, 1)
         Case "A" To "Z", "a" To "z", "\"
            ' Searching for a missing file...send 404 status downstream
            mo_HttpHeader.AddOrReplace "Status", 404
            
            m_Content = "Not Found"
            Me.Finish contentencoding_UTF8
            
            Exit Sub
         
         End Select
      End Select
      
      ' Not a missing file path, use passed data as content
      m_Content = p_FilePathOrContent
   
   Else
      ' Slurp file
      m_Content = libFso.ReadTextContent(p_FilePathOrContent, l_Utf16NoBom, p_CodePage)
      
   End If
   
   Set lo_Cache = libRc5Factory.C.Collection
   Set lo_SkipTags = libRc5Factory.C.Collection
   Set lo_StringBuilder = libRc5Factory.C.StringBuilder
   Set lo_StringTemplate = New VbFcgiLib.CWebStringTemplate
   
   l_TagStart = InStr(1, m_Content, m_OpenTag)
   
   Do While l_TagStart > 0
      
      l_TagEnd = InStr(l_TagStart, m_Content, m_CloseTag)
      
      If l_TagEnd > 0 Then
         ' Make sure we don't have a malformed document with an internal open tag
         If InStrRev(m_Content, m_OpenTag, l_TagEnd) > l_TagStart Then Err.Raise vbObjectError, , "Malformed template detected between characters " & l_TagStart & " and " & l_TagEnd
      
         ' Retrieve the tag content between the open and close tag identifiers
         l_Tag = LCase$(stringFlattenWhitespace(stringMidByEndIndex(m_Content, l_TagStart + Len(m_OpenTag), l_TagEnd)))
         
         If stringIsEmptyOrWhitespaceOnly(l_Tag) Then
            ' Tag is empty, skip it.
            l_TagStart = l_TagEnd + Len(m_CloseTag)
         
         Else
            ' Found tag
            
            l_SkipReplace = False
            l_SkipRescan = False
            
            If lo_Cache.Exists(l_Tag) Then
               ' Found tag value in cache, use it.
               lo_StringTemplate.Content = lo_Cache.Item(l_Tag)
               l_EncodeEntities = False   ' The cached replacement value was already encoded (or not) - use as-is
               l_SkipRescan = True  ' Move tag test to end of replaced tag
               l_SkipCache = True   ' Don't try to re-cache data
               
            Else
               ' Not found in cache
               
               If lo_SkipTags.Exists(l_Tag) Then
                  ' Tag was already processed this pass
                  ' Skip re-scanning to avoid infinite loops
                  l_SkipReplace = True
                  l_SkipRescan = True
                  
               Else
                  ' Tag has not been processed before on this chunk, so process it.
                  
                  lo_SkipTags.Add "", l_Tag  ' Prevent infinite loops by marking this tag as processed
                  
                  ' Tag not found in cache - ask host for replacement value
                  l_EncodeEntities = True ' Assume we're getting non HTML back from host after event
               
                  With lo_StringTemplate
                     .Clear
                     .SkipEncodeEntities = False
                     .SkipCache = False
                     l_SkipReplace = False
                  End With
                  
                  RaiseEvent FoundTag(l_Tag, lo_StringTemplate, l_SkipReplace)
                  
                  With lo_StringTemplate
                     l_SkipCache = .SkipCache
                     l_EncodeEntities = Not .SkipEncodeEntities
                  End With
               End If
            End If
            
            If l_SkipReplace Then
               ' There is nothing to replace the tag content with.
               ' Move tag search position to end of closing tag
               l_TagEnd = l_TagEnd + Len(m_CloseTag)
            
            Else
               ' Replace the tag with some other text
               l_ReplaceWith = lo_StringTemplate.Content
               lo_StringTemplate.Clear
               
               If l_EncodeEntities Then
                  l_ReplaceWith = htmlEscape(l_ReplaceWith)
               End If
               
               If Not l_SkipCache Then
                  ' Add replacement value to cache for quick re-use
                  lo_Cache.Add l_ReplaceWith, l_Tag
               End If
               
               l_Tag = stringMidByEndIndex(m_Content, l_TagStart, l_TagEnd + Len(m_CloseTag))
               
               With lo_StringBuilder
                  ' Replace tag with replacement string
                  .Append Left$(m_Content, l_TagStart - 1)
                  .Append l_ReplaceWith
                  
                  If l_SkipRescan Then l_NewContentEnd = .Length
                  
                  .Append Mid$(m_Content, l_TagEnd + Len(m_CloseTag))
                  
                  If l_SkipRescan Then l_TagEnd = l_NewContentEnd  ' Bump the next search position for non-Rescans to the end of the inserted text
                  
                  m_Content = .ToString
                  
                  .Clear
               End With
               
            End If
            
            If l_SkipRescan Then
               ' Don't loop back to check for tags within tags.
               ' Jump to end of found tag or inserted text and continue searching for tags from there
               
               lo_SkipTags.RemoveAll   ' Clear the collection of tags to skip on a given rescan
               l_TagStart = l_TagEnd
            End If
            
         End If
      
         ' Look for the next open tag
         l_TagStart = InStr(l_TagStart, m_Content, m_OpenTag)
         
     Else
         ' Unmatched tag found! Stop parsing this malformed document
         apiOutputDebugString "WARNING! Parsing aborted prematurely for malformed template document at " & Left$(p_FilePathOrContent, 255)
         Debug.Assert False
         Exit Do
      End If
   Loop
End Sub

Public Sub SetTagIdentifiers(ByVal p_OpenTag As String, ByVal p_CloseTag As String)
   If stringIsEmptyOrWhitespaceOnly(p_OpenTag) Then Err.Raise 5, , "Open tag required."
   If stringIsEmptyOrWhitespaceOnly(p_CloseTag) Then Err.Raise 5, , "Close tag required."
   If p_OpenTag = p_CloseTag Then Err.Raise 5, , "Open and Close tags must be different!"
      
   m_OpenTag = p_OpenTag
   m_CloseTag = p_CloseTag
End Sub

Public Property Get IBuilderInterface() As VbFcgiLib.IBuilder
   Set IBuilderInterface = Me
End Property

Private Sub Class_Initialize()
   m_OpenTag = "[["
   m_CloseTag = "]]"
   
   IBuilder_Reset
End Sub

Public Property Get ContentEncoding() As VbFcgiLib.e_ContentEncoding
   ' You must call the Finish method before you call this property.
   
   ' This property returns the content encoding enum of the Content byte array
   ' e.g. UTF8 or UTF16LE.
   
   If Not m_Finished Then Err.Raise 5, , "You must call the Finished method before requesting content encoding."
   
   ContentEncoding = m_ContentEncoding
End Property

Public Function EncodeEntities(ByVal p_Text As String) As String
   EncodeEntities = htmlEscape(p_Text)
End Function

Private Property Get IBuilder_Content() As Byte()
   ' You must call the Finish method before you call this property.
   ' Call this property to get your finished content as a Me.ContentEncoding format Byte Array
   
   If Not m_Finished Then Err.Raise 5, , "You must call the Finished method before requesting content."
   
   IBuilder_Content = ma_Content
End Property

Private Property Get IBuilder_HttpHeader() As VbFcgiLib.CHttpHeader
   Set IBuilder_HttpHeader = mo_HttpHeader
End Property

Private Sub IBuilder_Finish(Optional ByVal p_ContentEncoding As VbFcgiLib.e_ContentEncoding = contentencoding_RecommendedDefault)
   ' Call this method when you are finished building your HTML
   ' Once called, the Content, Length, and ContentEncoding properties will become valid.
      
   If p_ContentEncoding = contentencoding_RecommendedDefault Then p_ContentEncoding = contentencoding_UTF8
      
   Select Case p_ContentEncoding
   Case contentencoding_UTF8
      ma_Content = stringVbToUtf8(m_Content)
   
   Case contentencoding_UTF16_LE
      ma_Content = m_Content
   
   Case contentencoding_ISO8859_1
      ma_Content = stringVbToIso88591(m_Content)
      
   Case contentencoding_USASCII
      ma_Content = stringVbToUsAscii(m_Content)
      
   Case Else
      Err.Raise 5, , "Unknown content encoding enum: " & p_ContentEncoding
   End Select
   
   m_Content = ""
   m_Finished = True
   m_ContentEncoding = p_ContentEncoding
   m_Length = arraySize(ma_Content)
   
   RaiseEvent Finished
End Sub

Private Property Get IBuilder_IsFinished() As Boolean
   IBuilder_IsFinished = m_Finished
End Property

Private Property Get IBuilder_Length() As Long
   ' You must call the Finish method before you call this property.
   
   ' This property returns the length of the Content byte array.
   
   If Not m_Finished Then Err.Raise 5, , "You must call the Finished method before requesting the content length."
   
   IBuilder_Length = m_Length
End Property

Private Sub IBuilder_Reset()
   m_Finished = False
   m_ContentEncoding = contentencoding_Unknown
   
   Erase ma_Content
   m_Content = ""
   
   Set mo_HttpHeader = New VbFcgiLib.CHttpHeader
End Sub

Public Sub Finish(ByVal p_ContentEncoding As VbFcgiLib.e_ContentEncoding)
   IBuilder_Finish p_ContentEncoding
End Sub

Public Function Content() As Byte()
   Content = IBuilder_Content
End Function

Public Function Length() As Long
   Length = IBuilder_Length
End Function

Public Function IsFinished() As Boolean
   IsFinished = IBuilder_IsFinished
End Function

Private Sub mo_HttpHeader_BeforeBuildHttpHeader()
   ' Make sure the HTTP header includes the "Content-Type: text/html"
   ' and "Content-Length" headers.
   
   Dim l_Charset As String
   
   ' Add Content-Type header if it doesn't already exist
   If Not mo_HttpHeader.Exists("Content-Type") Then
      With mo_HttpHeader.Add("Content-Type", "text/html")
         Select Case Me.ContentEncoding
         Case contentencoding_UTF8
            l_Charset = "utf-8"
            
         Case contentencoding_UTF16_LE
            l_Charset = "utf-16le"
            
         Case contentencoding_USASCII
            l_Charset = "us-ascii"
         
         Case contentencoding_ISO8859_1
            l_Charset = "iso-8859-1"
            
         Case Else
            Debug.Assert False  ' Unhandled content encoding
            
         End Select
         
         If Not stringIsEmptyOrWhitespaceOnly(l_Charset) Then
            .KeyValuePairs.Add "charset", l_Charset
         End If
      End With
   End If
   
   ' Add or Replace Content-Length header if HTML build is finished
   If Me.IsFinished Then
      mo_HttpHeader.AddOrReplace "Content-Length", Me.Length
   End If
End Sub
