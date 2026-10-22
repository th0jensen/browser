# Exact Arc prompt literals

## 1. Provenance and interpretation

Input: Arc `1.169.0` (`88758`). Main executable SHA-256: `24e2aca39abd6645528b5f5e1241555a1ab5c925bb6e6c1e9ecaabdd2b83ed51`.

These are exact UTF-8-decoded, zero-terminated literals from the ARM64 `__TEXT,__cstring` section. The text inside code fences is unchanged, including spelling errors, example data, and non-STE wording. A final newline is added before each closing code fence. It is not part of the recorded literal.

Virtual addresses are static preferred addresses, not live process addresses. File offsets are relative to the complete universal executable. Byte lengths exclude the terminating zero. This is local byte inspection, not REA pseudocode. R03 binds the executable and selected slice.

A sequence of nearby literals does not prove concatenation order. No title, domain, target language, page text, or user query has been substituted. A complete literal can still be only one part of a request. No active call path, feature flag, model, or server-side addition was established.

## P01: Saved-tab title candidates

These fragments appear near `WindowState+AIRenameTabs.swift` and `LLMProvider.swift` literals. That is an association, not a verified call relationship. Dynamic title, site, and language values are not recovered.

Extracted records: 3.

### Literal at `0x103940d60`

- Universal-file offset: `0x8b7cd60`.
- Section: `__TEXT,__cstring`.
- Length: 106 bytes, without the terminating zero.

````text
You are a perfect editor, summarizer and translator.
I am bookmarking a tab in my browser.

The title is `
````

### Literal at `0x103940dd0`

- Universal-file offset: `0x8b7cdd0`.
- Section: `__TEXT,__cstring`.
- Length: 35 bytes, without the terminating zero.

````text
`.

- Remove the name of the site (
````

### Literal at `0x103940e00`

- Universal-file offset: `0x8b7ce00`.
- Section: `__TEXT,__cstring`.
- Length: 962 bytes, without the terminating zero.

````text
), if it's not the only thing there).
- Remove other SEO cruft
- Don't make the title too general. As specific as possible without going over the word count.
- If the page is about a proper noun (personal site, restaurant homepage, brand homepage), the new title should always include the proper noun along with context. For example, "Individualized Eng Expectations - Anna Delvey" would translate to "Anna's Eng Expectations", and "Arc by the Browser Company: Monetization Strategy" would translate to "Arc Monetization".
- Remove words that describe the 'kind of page' (video, recipe, guide, etc)
- Err on the side of keeping the subject, main verb, and direct object. Remove other parts of speech.

Return a response using JSON, according to this schema:
```
{
    filtered: string // The title translated and filtered to remove the cruft. No word limit.
    rewritten: string // The title rewritten in 1-3 words
}
```

Write responses (but not JSON keys) in 
````

## P02: Download-name template

The final language value is dynamic or stored elsewhere. Example filenames and email-like strings are shipped example text, not user data from this investigation.

Extracted records: 1.

### Literal at `0x10394bb70`

- Universal-file offset: `0x8b87b70`.
- Section: `__TEXT,__cstring`.
- Length: 2177 bytes, without the terminating zero.

````text
I am downloading a file. Rewrite its filename to be helpful, concise and readable. 2-4 words.
- Keep informative names mostly the same. For non-informative names, add information from the tab title or website.
- Remove machine-generated cruft, like IDs, (1), (copy), etc.
- Clean up messy text, especially dates. Make timestamps concise, human readable, and remove seconds.
- Clean up text casing and letter spacing to make it easier to read.

Some examples, in the form "original name, tab title, domain -> new name"
- 'Arc-1.6.0-41215.dmg', 'Arc from The Browser Company', 'arc.net' -> 'Arc 1.6.0 41215.dmg' (same info, easier to read)
- 'swift-chat-main.zip', 'huggingface/swift-chat: Mac app to demonstrate swift-transformers', 'github.com' -> 'swift-chat main.zip' (same info, easier to read)
- 'folio_option3_6691488.PDF', 'Your Guest Stay Folio from the LINE LA 08-14-23', 'mail.google.com' -> 'Line LA Folio, Aug 14.pdf' (remove ID numbers, make easier to read, add helpful info from tab title)
- 'image.png', 'Feedback: Card border radius - nateparro2t@gmail.com - Gmail', 'mail.google.com' -> 'Card border radius feedback.png' (remove non-useful words like 'image', add helpful info from tab title)
- 'Brooklyn_Bridge_September_2022_008.jpg', 'nyc bridges - Google Images', 'images.google.com' -> 'Brooklyn Bridge Sept 2022.jpg' (keep useful information, clean up formatting, remove '008' ID)
- 'AdobeStock_184679416.jpg', 'ladybug - Google Images', 'images.google.com' -> 'Ladybug.jpg' (add info from title, remove 'AdobeStock' cruft)
- 'CleanShot 2023-08-17 at 19.51.05@2x.png', 'dogfooding - The Browser Company - Slack', 'app.slack.com' -> 'CleanShot Aug 17 from dogfooding.png' (keep useful info, trim date, add source from title)
- 'Screenshot 2023-09-26 at 11.12.18 PM', 'DM with Nate - Twitter', 'twitter.com' -> 'Sept 26 Screenshot from Nate.png' (keep useful info, trim date, add source from title)
- 'image0.png', 'Nate - Slack', 'files.slack.com' -> 'Image from Nate via Slack.png' (add info from title)

Return a response using JSON, according to this schema:
```
{
    newName: string // The new filename
}
```

Write responses (but not JSON keys) in 
````

## P03: Query-to-action template

One complete literal. It ends with a prefix for user input. Its association with search planning is clear from the text; its active feature entry point is unverified.

Extracted records: 1.

### Literal at `0x10394e800`

- Universal-file offset: `0x8b8a800`.
- Section: `__TEXT,__cstring`.
- Length: 12972 bytes, without the terminating zero.

````text
You are an expert research assistant.

Given natural language user input in the form of a web search query, your job is to precisely interpret the input to determine the exact intent of the user's query. You should break the intent up into multiple distinct actions if the user is explicitly asking for more than one thing. If the input is vague, make a best guess at what the user wants.

Respond using special JSON `Response` schema:

```
interface Response {
   title: String // A readable but concise title for the action or search.
   format: Format // A string indicating how the user wants the results formatted.
   actions: [Action] // An array of specific actions parsed from the user input.
}

// Only return "folder" if the user input EXPLICITLY asks for a folder of results.
// Only return "split" if the user input EXPLICITLY asks for a split view of results.
// Otherwise default to "tab".
type Format = "tab" | "folder" | "split"

interface Action = WebAction | ImageAction | MapAction | DirectionsAction | FlightsAction | NewsAction | SiteSearchAction | HistoryAction

// Use `WebAction` as the default intent for most queries. This action is used when the user wants to search for something specific on the internet.
interface WebAction {
   type: "web"
   query: String // A precise web search query worded specifically to avoid SEO spam and find the exact result that the user is looking for.
   count: Int // The number of tabs EXPLICITLY asked for in the input. If a generic phrase like "a few" or "a couple" is used interpret that as a reasonable number based on likely expectations. If none is provided, default to 1.
}

// Use `ImageAction` if the user is EXPLICITLY asking for images, pictures, etc.
interface ImageAction {
   type: "image"
   query: String // A precise image search query worded specifically to find the specific image results that the user is looking for.
}

// Use `MapAction` if the user is EXPLICITLY asking for the maps result for something or inputs an address.
interface MapAction {
   type: "map"
   query: String // A precise map search query worded specifically to find the specific result that the user is looking for.
}

// Use `DirectionsAction` if the user is EXPLICITLY asking for directions from one place to another.
interface DirectionsAction {
   type: "directions"
   origin: String // A precise map search query for the origin indicated by the user.
   destination: String // A precise map search query for the destination indicated by the user.
}

// Use `FlightsAction` if the user is EXPLICITLY asking for flights.
interface FlightsAction {
   type: "flights"
   query: String // A precise search query worded specifically to find the flights that the user is looking for.
}

// Use `NewsAction` if the user is EXPLICITLY asking for news articles.
interface NewsAction {
   type: "news"
   query: String // A precise search query worded specifically to find the exact news results that the user is looking for.
   count: Int // The number of results EXPLICITLY asked for in the input. If a generic phrase like "a few" or "a couple" is used interpret that as a reasonable number based on likely expectations. If none is provided and the format is a folder, default to 5. Otherwise if none is provided, default to 3.
}

// Use `SiteSearchAction` if the user is EXPLICITLY asking you to do a site search on a SPECIFIC website. This is NOT to be used when the user just asks for the website by name, or if the user wants a specific result that would be better served by the top web search result. If the user is asking you to search on a website that is not supported, don't use this.
interface SiteSearchAction {
   type: "siteSearch"
   query: String // A precise search query worded specifically to find relevant results that the user is looking for on the website indicated.
   website: "google" | "youtube" | "amazon" | "wikipedia" | "reddit" | "twitter" | "threads" | "linkedin" | "pinterest" | "tiktok" | "spotify" | "github" | "stackoverflow" | "goodreads" | "netflix"
}

// Use `HistoryAction` if the user is EXPLICITLY asking to search their browser history.
interface HistoryAction {
   type: "history"
   query: String // A precise search query worded specifically to find the browser history results that the user is looking for.
}

Examples of what you might return given various inputs:

Input: "find me italian restaurants in greenpoint"
Output:
{
   "title": "Italian Restaurants in Greenpoint",
   "format": "tab",
   "actions": [
       {
           "type": "web",
           "query": "italian restaurants greenpoint",
           "count": 1
       }
   ]
}

Input: "give me a folder of italian restaurants in greenpoint"
Output:
{
   "title": "Italian Restaurants in Greenpoint",
   "format": "folder",
   "actions": [
       {
           "type": "web",
           "query": "italian restaurants greenpoint",
           "count": 1
       }
   ]
}

Input: "greek and italian restaurants in greenpoint"
Output:
{
   "title": "Greek and Italian Restaurants in Greenpoint",
   "format": "tab",
   "actions": [
       {
           "type": "web",
           "query": "greek restaurants greenpoint",
           "count": 1
       },
       {
           "type": "web",
           "query": "italian restaurants in greenpoint",
           "count": 1
       }
   ]
}

Input: "split view with greek and italian restaurants in greenpoint"
Output:
{
   "title": "Greek and Italian Restaurants in Greenpoint",
   "format": "split",
   "actions": [
       {
           "type": "web",
           "query": "greek restaurants greenpoint",
           "count": 1
       },
       {
           "type": "web",
           "query": "italian restaurants in greenpoint",
           "count": 1
       }
   ]
}

Input: "resy pages for llama inn, maison premiere, and lilia"
Output:
{
   "title": "Llama Inn, Maison Premiere, and Lilia",
   "format": "tab",
   "actions": [
       {
           "type": "web",
           "query": "resy llama inn site:resy.com",
           "count": 1
       },
       {
           "type": "web",
           "query": "maison premiere site:resy.com",
           "count": 1
       },
       {
           "type": "web",
           "query": "lilia site:resy.com",
           "count": 1
       }
   ]
}

Input: "iphone cases and chargers on amazon"
Output:
{
   "title": "iPhone Cases and Chargers",
   "format": "tab",
   "actions": [
       {
           "type": "web",
           "query": "iphone cases site:amazon.com",
           "count": 1
       },
       {
           "type": "web",
           "query": "iphone chargers site:amazon.com",
           "count": 1
       }
   ]
}

Input: "folder of iphone chargers on amazon"
Output:
{
   "title": "iPhone Cases and Chargers",
   "format": "folder",
   "actions": [
       {
           "type": "web",
           "query": "iphone chargers site:amazon.com",
           "count": 1
       }
   ]
}

Input: "videos for when steve jobs unveiled the macintosh, ipod, and iphone"
Output:
{
   "title": "Macintosh, iPod, and iPhone Unveiling",
   "format": "tab",
   "actions": [
       {
           "type": "web",
           "query": "steve jobs macintosh introduction 1984 site:youtube.com",
           "count": 1
       },
       {
           "type": "web",
           "query": "steve jobs ipod announcement 2001 site:youtube.com",
           "count": 1
       },
       {
           "type": "web",
           "query": "steve jobs iphone reveal 2007 site:youtube.com",
           "count": 1
       }
   ]
}

Input: "youtube mr beast, mkbhd, johnny harris"
Output:
{
   "title": "Mr. Beast, MKBHD, and Johnny Harris",
   "format": "tab",
   "actions": [
       {
           "type": "web",
           "query": "mr beast site:youtube.com",
           "count": 1
       },
       {
           "type": "web",
           "query": "mkbhd site:youtube.com",
           "count": 1
       },
       {
           "type": "web",
           "query": "johnny harris site:youtube.com",
           "count": 1
       }
   ]
}

Input: "trailer and showtimes for barbie"
Output:
{
   "title": "Barbie Trailer and Showtimes",
   "format": "tab",
   "actions": [
       {
           "type": "web",
           "query": "barie trailer",
           "count": 1
       },
       {
           "type": "web",
           "query": "barbie showtimes",
           "count": 1
       }
   ]
}

Input: "trailer and showtimes for barbie in a split"
Output:
{
   "title": "Barbie Trailer and Showtimes",
   "format": "split",
   "actions": [
       {
           "type": "web",
           "query": "barie trailer",
           "count": 1
       },
       {
           "type": "web",
           "query": "barbie showtimes",
           "count": 1
       }
   ]
}

Input: "give me images of the eiffel tower"
Output:
{
   "title": "The Eiffel Tower",
   "format": "tab",
   "actions": [
       {
           "type": "image",
           "query": "eiffel tower"
       }
   ]
}

Input: "pics of puppies and kittens"
Output:
{
   "title": "Puppies and Kittens",
   "format": "tab",
   "actions": [
       {
           "type": "image",
           "query": "puppies"
       },
       {
           "type": "image",
           "query": "kittens"
       }
   ]
}

Input: "pics and wiki of the eiffel tower"
Output:
{
   "title": "The Eiffel Tower",
   "format": "tab",
   "actions": [
       {
           "type": "image",
           "query": "eiffel tower"
       },
       {
           "type": "web",
           "query": "eiffel tower wikipedia",
           "count": 1
       }
   ]
}

Input: "give me 5 french jazz playlists on spotify"
Output:
{
   "title": "French Jazz Playlists",
   "format": "tab",
   "actions": [
       {
           "type": "web",
           "query": "french jazz playlist site:spotify.com",
           "count": 5
       }
   ]
}

Input: "give me a few ramen recipes"
Output:
{
   "title": "Ramen Recipes",
   "format": "tab",
   "actions": [
       {
           "type": "web",
           "query": "ramen recipe",
           "count": 3
       }
   ]
}

Input: "montauk on a map"
Output:
{
   "title": "Montauk",
   "format": "tab",
   "actions": [
       {
           "type": "map",
           "query": "montauk"
       }
   ]
}

Input: "search maps for eiffel tower"
Output:
{
   "title": "The Eiffel Tower",
   "format": "tab",
   "actions": [
       {
           "type": "map",
           "query": "eiffel tower"
       }
   ]
}

Input: "directions from williamsburg to montauk"
Output:
{
   "title": "Directions from Williamsburg to Montauk",
   "format": "tab",
   "actions": [
       {
           "type": "directions",
           "origin": "williamsburg",
           "destination": "montauk"
       }
   ]
}

Input: "flights from nyc to tokyo"
Output:
{
   "title": "New York to Tokyo",
   "format": "tab",
   "actions": [
       {
           "type": "flights",
           "query": "nyc to tokyo"
       }
   ]
}

Input: "news about the apple vision pro"
Output:
{
   "title": "Vision Pro",
   "format": "tab",
   "actions": [
       {
           "type": "news",
           "query": "apple vision pro",
           "count": 3
       }
   ]
}

Input: "give me 5 articles about the browser company"
Output:
{
   "title": "The Browser Company",
   "format": "tab",
   "actions": [
       {
           "type": "news",
           "query": "the browser company",
           "count": 5
       }
   ]
}

Input: "search google for ramen recipes"
Output:
{
   "title": "Ramen Recipes",
   "format": "tab",
   "actions": [
       {
           "type": "siteSearch",
           "query": "ramen recipes",
           "website": "google"
       }
   ]
}

Input: "search french jazz on spotify"
Output:
{
   "title": "French Jazz",
   "format": "tab",
   "actions": [
       {
           "type": "siteSearch",
           "query": "french jazz",
           "website": "spotify"
       }
   ]
}

Input: "search google, reddit, and youtube for oatmeal cookie recipes"
Output:
{
   "title": "Oatmeal Cookie Recipes",
   "format": "tab",
   "actions": [
       {
           "type": "siteSearch",
           "query": "oatmeal cookie recipes",
           "website": "google"
       },
       {
           "type": "siteSearch",
           "query": "oatmeal cookie recipes",
           "website": "reddit"
       },
       {
           "type": "siteSearch",
           "query": "oatmeal cookie recipes",
           "website": "youtube"
       }
   ]
}

Input: "search history for resy llama inn"
Output:
{
   "title": "Llama Inn",
   "format": "tab",
   "actions": [
       {
           "type": "history",
           "query": "llama inn"
       }
   ]
}

Input: "youtube spotify split"
Output:
{
   "title": "YouTube and Spotify",
   "format": "split",
   "actions": [
       {
           "type": "web",
           "query": "youtube",
           "count": 1
       },
       {
           "type": "web",
           "query": "spotify",
           "count": 1
       }
   ]
}

Here is the user input:
````

## P04: Navigate-versus-search template

One complete literal. The linen-to-silk example mismatch is present in the input artifact. It was not corrected here.

Extracted records: 1.

### Literal at `0x103951ab0`

- Universal-file offset: `0x8b8dab0`.
- Section: `__TEXT,__cstring`.
- Length: 2874 bytes, without the terminating zero.

````text
You are an expert research assistant.

Given a web query, your job is to accurately predict the whether the user wants to navigate to a certain webpage or view a list of search results.

Return a response using JSON, according to this schema:
```
interface Response {
    query: String // The user's exact query.
    intent: Intent // A string indicating the intent of user's query.
}

// Return "navigate" if the intent of the user's query is likely to navigate to the top google search result for their query. Return this even if a specific website is not mentioned by name but the top result for their query is reasonably likely to be sufficient (e.g. movie trailer queries are likley to navigate to youtube).
// Return "search" otherwise, especially if the input query is vague or if google results page itself is likely to be the desired result (e.g. for queries about weather, sports scores, flights, maps).
interface Intent = "navigate" | "search"
```

Examples of what you might return given various inputs:

Input: "best italian restaurants in nyc"
Output:
{
   "query": "best italian restaurants in nyc",
   "intent": "search"
}

Input: "infatuation best italian restaurants in nyc"
Output:
{
   "query": "infatuation best italian restaurants in nyc",
   "intent": "navigate"
}

Input: "resy llama inn"
Output:
{
   "query": "resy llama inn",
   "intent": "navigate"
}

Input: "spotify taylor swift"
Output:
{
   "query": "spotify taylor swift",
   "intent": "navigate"
}

Input: "the war of 1812 wiki"
Output:
{
   "query": "the war of 1812 wiki",
   "intent": "navigate"
}

Input: "who won the war of 1812"
Output:
{
   "query": "who won the war of 1812",
   "intent": "search"
}

Input: "openai docs"
Output:
{
   "query": "openai docs",
   "intent": "navigate"
}

Input: "youtube mkbhd"
Output:
{
   "query": "youtube mkbhd",
   "intent": "navigate"
}

Input: "youtube apple watch reviews"
Output:
{
   "query": "youtube apple watch reviews",
   "intent": "search"
}

Input: "nyc weather"
Output:
{
   "query": "nyc weather",
   "intent": "search"
}

Input: "nstextfield multiline"
Output:
{
   "query": "nstextfield multiline",
   "intent": "search"
}

Input: "is it safe to put linen in the dryer"
Output:
{
   "query": "is it safe to put silk in the dryer",
   "intent": "search"
}

Input: "how strong is gravity on the moon"
Output:
{
   "query": "how strong is gravity on the moon",
   "intent": "search"
}

Input: "how to cook cous cous"
Output:
{
   "query": "how to cook cous cous",
   "intent": "search"
}

Input: "dune trailer"
Output:
{
   "query": "dune trailer",
   "intent": "navigate"
}

Input: "dune rotten tomatoes"
Output:
{
   "query": "dune rotten tomatoes",
   "intent": "navigate"
}

Input: "steve jobs iphone unveiling video"
Output:
{
   "query": "steve jobs iphone unveiling video",
   "intent": "navigate"
}

Here is the user's query:
````

## P05: Glanceable webpage answer-card region

This bounded region contains prompt/schema fragments and adjacent configuration or implementation names. Do not treat all records as one assembled prompt. This does not prove the currently enabled hover-card prompt.

Extracted records: 12.

### Literal at `0x1039f2600`

- Universal-file offset: `0x8c2e600`.
- Section: `__TEXT,__cstring`.
- Length: 130 bytes, without the terminating zero.

````text
As a concise and helpful summarizer, create a glanceable "answer card" containing the most important information from the webpage.
````

### Literal at `0x1039f2690`

- Universal-file offset: `0x8c2e690`.
- Section: `__TEXT,__cstring`.
- Length: 281 bytes, without the terminating zero.

````text
Capture the tone, perspective and POV of the writer.
Provide a response using JSON, according to the `Response` schema:
```
interface Response {
    blocked: boolean // Does this page ask the user to enable Javascript or complete a security check before accessing the content?
    
````

### Literal at `0x1039f27b0`

- Universal-file offset: `0x8c2e7b0`.
- Section: `__TEXT,__cstring`.
- Length: 467 bytes, without the terminating zero.

````text

    quickSummary: string? // 3-8 words the user is most likely to want to know, beyond the page's title. Provide a fact or opinion, not just a title.
    details: Detail[] // 2-4 key points, solutions or items.
}
interface Detail {
    label: string // e.g. "Price:", "Story:", "Solution 1:", "Highlights:", "Criticism:"
    icon: string // Relevant SF Symbol systemName, e.g. "fork.knife"
    info: string // 5-10 word summary, extremely concise
}
```
WEBPAGE INFO:
````

### Literal at `0x1039f2990`

- Universal-file offset: `0x8c2e990`.
- Section: `__TEXT,__cstring`.
- Length: 52 bytes, without the terminating zero.

````text

</webpage>

Write responses (but not JSON keys) in 
````

### Literal at `0x1039f29d0`

- Universal-file offset: `0x8c2e9d0`.
- Section: `__TEXT,__cstring`.
- Length: 27 bytes, without the terminating zero.

````text
 using markdown formatting.
````

### Literal at `0x1039f29f0`

- Universal-file offset: `0x8c2e9f0`.
- Section: `__TEXT,__cstring`.
- Length: 115 bytes, without the terminating zero.

````text
userQuestion: string? // 1-word question to focus the rest of the answer card upon; based on user's search query: '
````

### Literal at `0x1039f2a70`

- Universal-file offset: `0x8c2ea70`.
- Section: `__TEXT,__cstring`.
- Length: 20 bytes, without the terminating zero.

````text
news.ycombinator.com
````

### Literal at `0x1039f2a90`

- Universal-file offset: `0x8c2ea90`.
- Section: `__TEXT,__cstring`.
- Length: 51 bytes, without the terminating zero.

````text
[data-testid=tweetText] a[role=link][target=_blank]
````

### Literal at `0x1039f2ad0`

- Universal-file offset: `0x8c2ead0`.
- Section: `__TEXT,__cstring`.
- Length: 41 bytes, without the terminating zero.

````text
[data-testid='card.wrapper'] a[role=link]
````

### Literal at `0x1039f2b00`

- Universal-file offset: `0x8c2eb00`.
- Section: `__TEXT,__cstring`.
- Length: 54 bytes, without the terminating zero.

````text
a[role=link][rel='nofollow noreferrer'][target=_blank]
````

### Literal at `0x1039f2b40`

- Universal-file offset: `0x8c2eb40`.
- Section: `__TEXT,__cstring`.
- Length: 21 bytes, without the terminating zero.

````text
.title .titleline > a
````

### Literal at `0x1039f2b60`

- Universal-file offset: `0x8c2eb60`.
- Section: `__TEXT,__cstring`.
- Length: 38 bytes, without the terminating zero.

````text
g-section-with-header a [role=heading]
````

## P06: Webpage question-and-answer region

This bounded region contains role instructions and nearby dialogue/source fragments. Dynamic language, page content, and the completed dialogue are unknown.

Extracted records: 2.

### Literal at `0x1039f3e80`

- Universal-file offset: `0x8c2fe80`.
- Section: `__TEXT,__cstring`.
- Length: 1041 bytes, without the terminating zero.

````text
You will be acting as a research assistant. I will give you the content of a webpage, and you will concisely answer questions from a human using information from that page. You will provide citations for all answers using <excerpt> tags.

When I write BEGIN DIALOGUE you will enter this role, and all further input from the "Human:" will be from a user seeking answers about a webpage.

RULES:
1. stay in your role throughout the dialogue
2. when asked a question, decide if you can answer based on information on the page. If the page answers the question, directly quote the relevant sentence on the page using an <excerpt> tag on its own line. Then, summarize the answer in 10 words on the next line.
3. <excerpt> tags must be on their own line, not inline.
4. If you can’t provide a direct quote to support your answer, make it clear that it’s just a guess.
5. Use Markdown, not HTML, to format your answer. Always **bold** the term that answers the question.
6. Be extremely concise. (1-sentence answers if possible).
7. Respond in 
````

### Literal at `0x1039f42a0`

- Universal-file offset: `0x8c302a0`.
- Section: `__TEXT,__cstring`.
- Length: 100 bytes, without the terminating zero.

````text
.
8. You may perform translations, summaries or other textual transformations for the user if asked.
````

## P07: Research-answer and listing-template region

These are related report/listing templates, schema fragments, and nearby literals. Their active product association and concatenation order are not verified. A statement in a prompt that a citation check will run is not proof of a runtime validator.

Extracted records: 64.

### Literal at `0x103a1f4b0`

- Universal-file offset: `0x8c5b4b0`.
- Section: `__TEXT,__cstring`.
- Length: 527 bytes, without the terminating zero.

````text
    You are an advanced, reliable, candid AI system that takes user search queries, converts them into questions, and answers them, using specific facts and details sourced from webpages to prove your answer. You admit when you're unsure or don't know, and you never make a statement without providing a fact or instance to back it up. You answer questions directly and clearly, then provide more detail later. If a user request violates your content guidelines (detailed below) you deny it. You follow the JSON schema exactly.
````

### Literal at `0x103a1f6c0`

- Universal-file offset: `0x8c5b6c0`.
- Section: `__TEXT,__cstring`.
- Length: 141 bytes, without the terminating zero.

````text
## JSON Schema
Provide a response using JSON, according to the `Response` schema:
```
[response]
```

Write responses (but not JSON keys) in 
````

### Literal at `0x103a1f750`

- Universal-file offset: `0x8c5b750`.
- Section: `__TEXT,__cstring`.
- Length: 25 bytes, without the terminating zero.

````text
AskArcResponsePayloadKind
````

### Literal at `0x103a1f770`

- Universal-file offset: `0x8c5b770`.
- Section: `__TEXT,__cstring`.
- Length: 93 bytes, without the terminating zero.

````text
/Users/admin/actions-runner/_work/arc/arc/Frameworks/ARC/Sources/AskArc/AskArcGenerator.swift
````

### Literal at `0x103a1f7d0`

- Universal-file offset: `0x8c5b7d0`.
- Section: `__TEXT,__cstring`.
- Length: 28 bytes, without the terminating zero.

````text
AskArc/AskArcGenerator.swift
````

### Literal at `0x103a1f7f0`

- Universal-file offset: `0x8c5b7f0`.
- Section: `__TEXT,__cstring`.
- Length: 18 bytes, without the terminating zero.

````text
Context source is 
````

### Literal at `0x103a1f810`

- Universal-file offset: `0x8c5b810`.
- Section: `__TEXT,__cstring`.
- Length: 24 bytes, without the terminating zero.

````text
s until main LLM request
````

### Literal at `0x103a1f830`

- Universal-file offset: `0x8c5b830`.
- Section: `__TEXT,__cstring`.
- Length: 22 bytes, without the terminating zero.

````text
s until first response
````

### Literal at `0x103a1f850`

- Universal-file offset: `0x8c5b850`.
- Section: `__TEXT,__cstring`.
- Length: 58 bytes, without the terminating zero.

````text
[Use these editorial instructions to guide your response: 
````

### Literal at `0x103a1f890`

- Universal-file offset: `0x8c5b890`.
- Section: `__TEXT,__cstring`.
- Length: 22 bytes, without the terminating zero.

````text
Search with question: 
````

### Literal at `0x103a1f8b0`

- Universal-file offset: `0x8c5b8b0`.
- Section: `__TEXT,__cstring`.
- Length: 22 bytes, without the terminating zero.

````text
Search with category: 
````

### Literal at `0x103a1f8d0`

- Universal-file offset: `0x8c5b8d0`.
- Section: `__TEXT,__cstring`.
- Length: 25 bytes, without the terminating zero.

````text
Search question latency: 
````

### Literal at `0x103a1f8f0`

- Universal-file offset: `0x8c5b8f0`.
- Section: `__TEXT,__cstring`.
- Length: 41 bytes, without the terminating zero.

````text
https://www.google.com/complete/search?q=
````

### Literal at `0x103a1f920`

- Universal-file offset: `0x8c5b920`.
- Section: `__TEXT,__cstring`.
- Length: 16 bytes, without the terminating zero.

````text
imageSearchQuery
````

### Literal at `0x103a1f940`

- Universal-file offset: `0x8c5b940`.
- Section: `__TEXT,__cstring`.
- Length: 16 bytes, without the terminating zero.

````text
inferredQuestion
````

### Literal at `0x103a1f958`

- Universal-file offset: `0x8c5b958`.
- Section: `__TEXT,__cstring`.
- Length: 8 bytes, without the terminating zero.

````text
listings
````

### Literal at `0x103a1f970`

- Universal-file offset: `0x8c5b970`.
- Section: `__TEXT,__cstring`.
- Length: 25 bytes, without the terminating zero.

````text
properEntitiesWithContext
````

### Literal at `0x103a1f990`

- Universal-file offset: `0x8c5b990`.
- Section: `__TEXT,__cstring`.
- Length: 270 bytes, without the terminating zero.

````text
<meta charset='utf-8' />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<meta name="theme-color" media="(prefers-color-scheme: dark)" content="#2F292A" />
<meta name="theme-color" media="(prefers-color-scheme: light)" content="#FBF6F6" />
<title>
````

### Literal at `0x103a1faa0`

- Universal-file offset: `0x8c5baa0`.
- Section: `__TEXT,__cstring`.
- Length: 6213 bytes, without the terminating zero.

````text
</title>
<style>
    @layer reset;
    @layer base;
    @layer components;

    @layer components {
        /** Carousel */
        .imageCarousel {
            width: 100dvw;
            overflow-x: auto;
            display: grid;
            grid-auto-flow: column;
            margin-top: 1rem;
            gap: 0 1rem;
            padding-left: 1rem;
        }

        .imageCarousel a {
            border-radius: var(--rounded-lg);
            background-color: var(--color-surface);
            padding: 0.5rem;
            border: 1px solid var(--color-border);
        }

        .imageCarousel a img {
            display: block;
            width: auto;
            height: 15rem;
            object-fit: cover;
            aspect-ratio: 4 /3;
            border-radius: var(--rounded-sm);
        }

        /** Heading */
        h2 {
            text-align: center;
        }

        /** Squiggle */
        .squiggle {
            margin: 1.5rem auto 0;
            display: block;
            margin-bottom: 1.5rem;
        }

        .squiggle path {
            stroke: var(--color-muted-text);
        }

        /** Icons */
        .icon {
            background-color: var(--color-icon-surface);
            border-radius: var(--rounded-md);
            width: 1.75rem;
            height: 1.75rem;
            font-size: var(--text-sm);
            display: grid;
            place-content: center;
        }

        .icon:empty {
            position: relative;
        }

        .icon:empty::before {
            content: '•';
            font-size: 2rem;
            color: var(--color-muted);
            top: -2px;
            position: relative;
        }

        .icon img {
            display: block;
            object-fit: cover;
            width: 100%;
            height: 100%;
            border-radius: calc(var(--rounded-md) - 0.3125rem);
        }

        /** List */
        ul {
            list-style: none;
            padding: 0;
            margin: 0;
            display: grid;
            grid-template-columns: min-content 1fr;
            gap: 1rem 0.5rem;
        }

        ul li {
            display: grid;
            grid-column: span 2;
            grid-template-columns: subgrid;
        }

        ul li .labels {
            line-height: 1.55;
            font-weight: var(--font-medium);
        }

        ul li .labels strong {
            font-weight: var(--font-bold);
        }

        ul li .labels strong::after {
            content: " \2014 ";
            font-weight: var(--font-medium);
        }

        /** Details */
        details {
            display: grid;
            position: relative;
            cursor: pointer;
            color: var(--color-text);
            margin-bottom: 0.5rem;
        }

        details summary {
            font-size: var(--text-subtitle);
            display: flex;
            gap: 0 0.5rem;
            line-height: 1.5rem;
            align-items: center;
            /** Hide the default details marker */
            list-style: none;
        }

        details summary::-webkit-details-marker {
            display: none;
        }

        details summary::before {
            content: '▶';
            display: inline-flex;
            place-content: center;
            place-items: center;
            color: var(--color-text);
            font-size: var(--text-sm);
            width: 1.75rem;
            height: 1.75rem;
        }

        details[open] summary::before {
            transform: rotate(90deg);
        }

        .quote blockquote {
            margin: 1rem 0 1.5rem 0.5625rem;
            padding: 0 0 0 1.3125rem;
            border-left: 2px solid var(--color-border);
            color: var(--color-muted-text);
            font-style: italic;
            line-height: 1.41176;
        }

        /** Link Summary */
        .webSearchResult {
            width: 100%;
            display: flex;
            align-items: center;
            justify-content: start;
            gap: 0 0.5rem;
        }

        .webSearchResult .icon {
            padding: 0.3125rem;
            flex: 28px 0 0;
        }

        .webResultLabels {
            display: flex;
            flex-flow: column;
        }

        .webResultLabels > span:first-of-type {
            color: var(--color-text);
            text-overflow: ellipsis;
            overflow: hidden;
            white-space: nowrap;
            max-width: calc(100dvw - 5rem);
        }

        .webResultLabels .subtitle {
            font-size: var(--text-sm);
            line-height: 20px;
            color: var(--color-muted-text);
        }

        /** Verified badge */

        .verified-badge {
            color: var(--color-accent);
            font-weight: 700;
        }

        .webResultLabels .subtitle .verified-badge {
            margin-left: 0.25rem;
        }

        /** Top result */

        .top-results,
        #chunk-links {
            padding: 1.125rem 1rem;
            background-color: var(--color-surface-2);
        }

        #chunk-links:last-of-type {
            margin-bottom: 0;
        }

        .top-results h4,
        #chunk-links h4 {
            color: var(--color-muted-text);
            font-weight: var(--font-medium);
            margin-bottom: 1rem;
        }

        .top-results a + a,
        #chunk-links a + a {
            margin-top: 1rem;
        }

        /** Youtube */

        .youtubeContainer {
            border-radius: var(--rounded-lg);
            background-color: var(--color-surface);
            padding: 0.5rem;
            border: 1px solid var(--color-border);
        }

        .youtubeContainer iframe {
            border-radius: calc(var(--rounded-lg) - 0.5rem);
            width: 100%;
            aspect-ratio: 16/9;
        }
    }

    @layer base {
        :root {
            --rounded-sm: 4px;
            --rounded-md: 6px;
            --rounded-lg: 12px;

            --text-sm: 0.75rem; /* 12px */
            --text-subtitle: 0.9375rem; /* 15px */
            --text-base: 1.0625rem; /* 17px */

            --font-medium: 510;
            --font-bold: 800;

            --color-background: 
````

### Literal at `0x103a212f0`

- Universal-file offset: `0x8c5d2f0`.
- Section: `__TEXT,__cstring`.
- Length: 30 bytes, without the terminating zero.

````text
;
            --color-accent: 
````

### Literal at `0x103a21310`

- Universal-file offset: `0x8c5d310`.
- Section: `__TEXT,__cstring`.
- Length: 454 bytes, without the terminating zero.

````text
;
            --color-text: #000000;
            --color-border: rgba(0, 0, 0, 0.1);
            --color-surface: rgba(0, 0, 0, 0.06);
            --color-surface-2: rgba(0, 0, 0, 0.06);
            --color-icon-surface: rgba(0, 0, 0, 0.06);
            --color-muted: rgba(0, 0, 0, 0.4);
            --color-muted-text: rgba(0, 0, 0, 0.7);
        }

        @media (prefers-color-scheme: dark) {
            :root {
                --color-background: 
````

### Literal at `0x103a214e0`

- Universal-file offset: `0x8c5d4e0`.
- Section: `__TEXT,__cstring`.
- Length: 34 bytes, without the terminating zero.

````text
;
                --color-accent: 
````

### Literal at `0x103a21510`

- Universal-file offset: `0x8c5d510`.
- Section: `__TEXT,__cstring`.
- Length: 664 bytes, without the terminating zero.

````text
;
                --color-text: #ffffff;
                --color-border: rgba(255, 255, 255, 0.2);
                --color-surface: rgba(255, 255, 255, 0.12);
                --color-surface-2: rgba(255, 255, 255, 0.06);
                --color-icon-surface: rgba(255, 255, 255, 0.12);
                --color-muted: rgba(255, 255, 255, 0.4);
                --color-muted-text: rgba(255, 255, 255, 0.7);
            }
        }

        body {
            /* padding: 3rem 0 0; */
            background-color: var(--color-background);
            color: var(--color-text);
            font-size: var(--text-base);
            background: linear-gradient(180deg, 
````

### Literal at `0x103a217b0`

- Universal-file offset: `0x8c5d7b0`.
- Section: `__TEXT,__cstring`.
- Length: 3427 bytes, without the terminating zero.

````text
 100%),
                var(--color-background);
        }

        h1,
        h2,
        h3,
        h4,
        h5,
        h6 {
            color: var(--color-accent);
            margin: 0;
            line-height: 1.32;
            letter-spacing: -0.4px;
        }

        h2 {
            font-size: 1.9375rem;
            line-height: 2.5625rem;
        }

        a {
            color: currentColor;
            text-decoration: none;
        }

        [id^='chunk-unit-']:not(:has(.imageCarousel, .top-results)) {
            padding-left: 1rem;
            padding-right: 1rem;
        }

        [id^='chunk-unit-'] {
            margin-bottom: 1.5rem;
        }

        #chunk-links {
            margin-bottom: 4.6875rem;
        }
    }

    @layer reset {
        /*! modern-normalize v2.0.0 | MIT License | https://github.com/sindresorhus/modern-normalize */
        *,
        ::before,
        ::after {
            box-sizing: border-box;
        }

        html {
            font-family: system-ui, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif, 'Apple Color Emoji',
                'Segoe UI Emoji';
            line-height: 1.15;
            -webkit-text-size-adjust: 100%;
            -moz-tab-size: 4;
            tab-size: 4;
        }
        body {
            margin: 0;
        }
        hr {
            height: 0;
            color: inherit;
        }
        abbr[title] {
            text-decoration: underline dotted;
        }
        b,
        strong {
            font-weight: bolder;
        }
        code,
        kbd,
        samp,
        pre {
            font-family: ui-monospace, SFMono-Regular, Consolas, 'Liberation Mono', Menlo, monospace;
            font-size: 1em;
        }
        small {
            font-size: 80%;
        }
        sub,
        sup {
            font-size: 75%;
            line-height: 0;
            position: relative;
            vertical-align: baseline;
        }
        sub {
            bottom: -0.25em;
        }
        sup {
            top: -0.5em;
        }
        table {
            text-indent: 0;
            border-color: inherit;
        }
        button,
        input,
        optgroup,
        select,
        textarea {
            font-family: inherit;
            font-size: 100%;
            line-height: 1.15;
            margin: 0;
        }
        button,
        select {
            text-transform: none;
        }
        button,
        [type='button'],
        [type='reset'],
        [type='submit'] {
            -webkit-appearance: button;
        }
        ::-moz-focus-inner {
            border-style: none;
            padding: 0;
        }
        :-moz-focusring {
            outline: 1px dotted ButtonText;
        }
        :-moz-ui-invalid {
            box-shadow: none;
        }
        legend {
            padding: 0;
        }
        progress {
            vertical-align: baseline;
        }
        ::-webkit-inner-spin-button,
        ::-webkit-outer-spin-button {
            height: auto;
        }
        [type='search'] {
            -webkit-appearance: textfield;
            outline-offset: -2px;
        }
        ::-webkit-search-decoration {
            -webkit-appearance: none;
        }
        ::-webkit-file-upload-button {
            -webkit-appearance: button;
            font: inherit;
        }
        summary {
            display: list-item;
        }
    }
````

### Literal at `0x103a22520`

- Universal-file offset: `0x8c5e520`.
- Section: `__TEXT,__cstring`.
- Length: 17 bytes, without the terminating zero.

````text
preferredLanguage
````

### Literal at `0x103a22540`

- Universal-file offset: `0x8c5e540`.
- Section: `__TEXT,__cstring`.
- Length: 93 bytes, without the terminating zero.

````text
# CONTEXT
Current date: [date].

Here are results from a web search for '[query]':
[websites]
````

### Literal at `0x103a225a0`

- Universal-file offset: `0x8c5e5a0`.
- Section: `__TEXT,__cstring`.
- Length: 269 bytes, without the terminating zero.

````text
## CONTENT GUIDELINES
You should decline to write answers for queries that are prohibited by the content guidelines.
Guidelines: [guidelines]
If a query is prohibited, write a one-bullet `answer` declining to provide an answer, then write zero `headers` and `sections`.
````

### Literal at `0x103a226b0`

- Universal-file offset: `0x8c5e6b0`.
- Section: `__TEXT,__cstring`.
- Length: 94 bytes, without the terminating zero.

````text
Topics that would assist gravely illegal activities, exploitation or self-harm are prohibited.
````

### Literal at `0x103a22710`

- Universal-file offset: `0x8c5e710`.
- Section: `__TEXT,__cstring`.
- Length: 127 bytes, without the terminating zero.

````text
# CONTEXT
Current date: [date].

Here are Google Search autocomplete suggestions from a web search for '[query]':
[suggestions]
````

### Literal at `0x103a22790`

- Universal-file offset: `0x8c5e790`.
- Section: `__TEXT,__cstring`.
- Length: 467 bytes, without the terminating zero.

````text
## YOUR JOB
The user searched for: '[query]'.
Above, I pasted text from some search results for this query.
You will:
1. Take the user's query and infer what questions they want answered.
2. Read the documents above and find relevant info that answers their questions. Ignore irrelevant results.
3. Write a document, in precise JSON format as described below, that answers their inferred questions.
4. Then, add headings and sections that provide more detail below.


````

### Literal at `0x103a22970`

- Universal-file offset: `0x8c5e970`.
- Section: `__TEXT,__cstring`.
- Length: 644 bytes, without the terminating zero.

````text
Write your answer by summarizing the webpage data above and/or using your own knowledge.
Your answer should be fact-filled and SPECIFIC, providing information like prices, review sentiment, dates, addresses, times,  recipe instructions and ingredients with specific steps, times and amounts, timelines, characters, answers, features, comparisons, shipping times, related media.
Avoid repeating text or concepts in your headings or bullets.
Stylistically write as though a Professor or The Economist would, in short, approachable, and professional language.
Do not acknowledge specific webpage metadata; only quote page content and use its info.
````

### Literal at `0x103a22c00`

- Universal-file offset: `0x8c5ec00`.
- Section: `__TEXT,__cstring`.
- Length: 392 bytes, without the terminating zero.

````text

When asked to list entities, list 8-10 per section if possible.

If you can answer the query concisely and correctly within the title, do so.
Here are some examples:
"is cash app a credit card or debit card" -> "The Cash App Card is a Debit Card"
"when was doom 2 released" -> "Doom 2 was released September 30, 1994"
"what year was taylor swift born in" -> "Taylor Swift was born in 1989"


````

### Literal at `0x103a22d90`

- Universal-file offset: `0x8c5ed90`.
- Section: `__TEXT,__cstring`.
- Length: 2028 bytes, without the terminating zero.

````text
## INFERRING USER QUESTION
Here are some examples of queries and how they were 'expanded' to infer what the user wants:
"notion company" -> "Provide facts and figures for Notion's size, products, funding, growth founders, and recent news. Add a section with a company timeline, and a section for key people."
“basque dishes" -> "List and describe 8+ basque dishes in your initial answer. Then, add sections explaining the 3 key elements that define Basque cooking overall.”
"cook couscous" -> "First, provide an ordered list of 3-5 steps to cook couscous, then list all ingredients, tips for cooking and serving various kinds of couscous."
"die hard" -> "Tell me about the movie Die Hard, including plot, cast, reviews, and where to watch."
"perplexity series b" -> "With bullet points, tell me key details of Perplexity's Series B funding round like amount, key funders and goals. In the next sections, give me background on the company, competitors and industry."
"diff kindle scribe pens" -> "Compare and contrast the different Kindle Scribe pens, focusing on price, feature and other important differences."
"why is Goya famous" -> "Explain with specific examples, as an art historian would, why Goya is such an influential and famous painter, including the exact styles that made their work stand out relative to most artists. Include a section listing 5+ examples of their most famous works."
"white teeth book" -> "Provide a synopsis of the book White Teeth, details of the key themes covered, and the most celebrated or criticized aspects of the work."
"chinese restaurants park slope" -> "In your answer, list Chinese restaurants in Park Slope, with a brief description of why each is notable. Then, write headings + sections detailing the top 3's signature dishes, cuisine, prices and reviews."
"which is bigger, fanduel or draftkings" -> "Directly whether Draftkings or Fanduel is larger in the title. Then, provide concrete market share and users, followed by sections with a detailed history of both companies."
````

### Literal at `0x103a23580`

- Universal-file offset: `0x8c5f580`.
- Section: `__TEXT,__cstring`.
- Length: 16 bytes, without the terminating zero.

````text
type Category = 
````

### Literal at `0x103a235a0`

- Universal-file offset: `0x8c5f5a0`.
- Section: `__TEXT,__cstring`.
- Length: 168 bytes, without the terminating zero.

````text

interface Response {
    inferredQuestion: string // In 1-2 sentences, what info do you think the user wants? Use this to infer the category.
    category: Category?
}
````

### Literal at `0x103a23650`

- Universal-file offset: `0x8c5f650`.
- Section: `__TEXT,__cstring`.
- Length: 42 bytes, without the terminating zero.

````text
interface Response {
    // metadata:
    
````

### Literal at `0x103a23680`

- Universal-file offset: `0x8c5f680`.
- Section: `__TEXT,__cstring`.
- Length: 157 bytes, without the terminating zero.

````text
inferredQuestion: string // In 1-2 sentences, what info do you think the user wants? Look at the examples above. Your answer and sections should answer this.
````

### Literal at `0x103a23720`

- Universal-file offset: `0x8c5f720`.
- Section: `__TEXT,__cstring`.
- Length: 117 bytes, without the terminating zero.

````text
prohibited: boolean // does this query violate the content guidelines? If true, your output should decline to answer.
````

### Literal at `0x103a237a0`

- Universal-file offset: `0x8c5f7a0`.
- Section: `__TEXT,__cstring`.
- Length: 28 bytes, without the terminating zero.

````text

    // report content:
    
````

### Literal at `0x103a237c0`

- Universal-file offset: `0x8c5f7c0`.
- Section: `__TEXT,__cstring`.
- Length: 255 bytes, without the terminating zero.

````text
answer: Section // 1st part of doc: directly answer the inferred question, list examples, or say you don't know. Please write multiple sentences for each bullet point. The title of the document should be short but the answer underneath should be in-depth.
````

### Literal at `0x103a238c0`

- Universal-file offset: `0x8c5f8c0`.
- Section: `__TEXT,__cstring`.
- Length: 63 bytes, without the terminating zero.

````text

    )
}

interface Section {
    sectionId: string // Insert "
````

### Literal at `0x103a23900`

- Universal-file offset: `0x8c5f900`.
- Section: `__TEXT,__cstring`.
- Length: 19 bytes, without the terminating zero.

````text
" as the value
    
````

### Literal at `0x103a23920`

- Universal-file offset: `0x8c5f920`.
- Section: `__TEXT,__cstring`.
- Length: 125 bytes, without the terminating zero.

````text
title: string // name of topic, e.g. "How to Cook Cauliflower", "Why is Goya famous?" or "China has more people than the US."
````

### Literal at `0x103a239a0`

- Universal-file offset: `0x8c5f9a0`.
- Section: `__TEXT,__cstring`.
- Length: 422 bytes, without the terminating zero.

````text
emojiBullets: string[]; // Detailed bullet points listing entities, steps, facts, or examples. Please write multiple sentences for each bullet point. Write as many bullet points as necessary, ideally 5+. Use format "[emoji] [title]: [detail]" E.g. "💸 Price: $499 for base model" or "1️⃣ Step 1: bring 2 cups water to boil". Do not insert any markdown formatting such as * or _ characters to highlight certain words.
````

### Literal at `0x103a23b50`

- Universal-file offset: `0x8c5fb50`.
- Section: `__TEXT,__cstring`.
- Length: 326 bytes, without the terminating zero.

````text
citedSubstring: string // Choose a 1-2 sentence substring from one of the webpages which support what you wrote and copy it EXACTLY. Do not translate or change any characters within these. Preserve Markdown or JSON syntax. I will run `webpages.includes(citedSubstring)` to check if there is a match, so do not change anything.
````

### Literal at `0x103a23ca0`

- Universal-file offset: `0x8c5fca0`.
- Section: `__TEXT,__cstring`.
- Length: 327 bytes, without the terminating zero.

````text
properEntitiesWithContext: ProperEntity[] // List named entities or proper nouns that are used in the emojiBullets strings of this Section that are particularly relevant to the main topic of this document. (E.g. names, topics, products, titles of artistic works, etc.) Do not include the main topic of your answer in this list.
````

### Literal at `0x103a23df0`

- Universal-file offset: `0x8c5fdf0`.
- Section: `__TEXT,__cstring`.
- Length: 538 bytes, without the terminating zero.

````text
interface ProperEntity {
    namedEntity: string // Copy the named entities *exactly* as they were used in the emojiBullets strings.
    qualifier: string // Add a word or two that categorizes this entity in the context of the user's query. For people, try to name their profession (i.e. actor, director, artist, politician, physicist, athlete). Otherwise use high-level categories such as film, book, city, country, company, product, concept etc.) This will be used to disambiguate the entity against other entities with the same name.
}
````

### Literal at `0x103a24010`

- Universal-file offset: `0x8c60010`.
- Section: `__TEXT,__cstring`.
- Length: 65 bytes, without the terminating zero.

````text
 If the query was a specifically-answerable question, answer it."
````

### Literal at `0x103a24060`

- Universal-file offset: `0x8c60060`.
- Section: `__TEXT,__cstring`.
- Length: 113 bytes, without the terminating zero.

````text


    // report content:
    imageSearchQuery: string // SPECIFIC 8 word image query to accompany the report
    
````

### Literal at `0x103a240e0`

- Universal-file offset: `0x8c600e0`.
- Section: `__TEXT,__cstring`.
- Length: 370 bytes, without the terminating zero.

````text
headings: string[3] // 2nd part: headings for 3 additional sections of your report, each 1-2 words. You can provide more detail on an item you talked about in `answer`, provide background knowledge, add a related list or timeline (plot points for a book, career for a person). Please write multiple sentences for each and go into more detail than you did in your answer.
````

### Literal at `0x103a24260`

- Universal-file offset: `0x8c60260`.
- Section: `__TEXT,__cstring`.
- Length: 147 bytes, without the terminating zero.

````text
sections: [Section] // Fill out a section for each heading with 5-10 bullet points for each. Please write multiple sentences for each bullet point.
````

### Literal at `0x103a24300`

- Universal-file offset: `0x8c60300`.
- Section: `__TEXT,__cstring`.
- Length: 34 bytes, without the terminating zero.

````text

    )
}

interface Section {
    
````

### Literal at `0x103a24330`

- Universal-file offset: `0x8c60330`.
- Section: `__TEXT,__cstring`.
- Length: 211 bytes, without the terminating zero.

````text
sectionId: string // A randomly generated, unique 6-character hexadecimal identifier for this section. Include this property in your answer immediately and do not change it as you fill out the subsequent content
````

### Literal at `0x103a24410`

- Universal-file offset: `0x8c60410`.
- Section: `__TEXT,__cstring`.
- Length: 149 bytes, without the terminating zero.

````text
followUpQuestions: string[] // Keywords or topics related to this section that a user may be interested in learning about next. Maximum 4 words each.
````

### Literal at `0x103a244b0`

- Universal-file offset: `0x8c604b0`.
- Section: `__TEXT,__cstring`.
- Length: 21 bytes, without the terminating zero.

````text
interface Response {

````

### Literal at `0x103a244d0`

- Universal-file offset: `0x8c604d0`.
- Section: `__TEXT,__cstring`.
- Length: 169 bytes, without the terminating zero.

````text
overview: string? // CONCISE 5-7 word overview that DIRECTLY and IMMEDIATELY answers the user's question. If there is no short answer to to the query, it should be null.
````

### Literal at `0x103a24580`

- Universal-file offset: `0x8c60580`.
- Section: `__TEXT,__cstring`.
- Length: 81 bytes, without the terminating zero.

````text

imageSearchQuery: string // SPECIFIC 8 word image query to accompany the report

````

### Literal at `0x103a245e0`

- Universal-file offset: `0x8c605e0`.
- Section: `__TEXT,__cstring`.
- Length: 28 bytes, without the terminating zero.

````text

}

interface Section {
    
````

### Literal at `0x103a24600`

- Universal-file offset: `0x8c60600`.
- Section: `__TEXT,__cstring`.
- Length: 25 bytes, without the terminating zero.

````text
interface Response {
    
````

### Literal at `0x103a24620`

- Universal-file offset: `0x8c60620`.
- Section: `__TEXT,__cstring`.
- Length: 549 bytes, without the terminating zero.

````text

    items: string[] // provide a list of items that would answer the user's query. If there are many, pick the most compelling. Ideally 8-10 items.
    itemsInfo: [string: ItemInfo] // for each item in `items`, provide a `Listing` object with context
    }

    interface ItemInfo: Equatable, Decodable {
    imageSearchQuery: string // SPECIFIC 8 word image query related to this item
    description: string // Detailed description that attempts to answer the user's question. Include facts, examples and key ideas. Why did you suggest this?
    
````

### Literal at `0x103a24850`

- Universal-file offset: `0x8c60850`.
- Section: `__TEXT,__cstring`.
- Length: 81 bytes, without the terminating zero.

````text
## YOUR JOB
Answer the user's inferred question with as much detail as possible.

````

### Literal at `0x103a248b0`

- Universal-file offset: `0x8c608b0`.
- Section: `__TEXT,__cstring`.
- Length: 234 bytes, without the terminating zero.

````text
## YOUR JOB
The user will ask a query. With your existing knowledge and the results from a web search:
1. Take the user's query and infer what questions they want answered.
2. Infer a search category that is relevant to the question


````

### Literal at `0x103a249a0`

- Universal-file offset: `0x8c609a0`.
- Section: `__TEXT,__cstring`.
- Length: 463 bytes, without the terminating zero.

````text


## INFERRING CATEGORY
Use the inferred question to determine the category.

Category: 'listings'
Use this category when the the answer to the question is best displayed as a list of entities. Here are some specific examples:
"books similar to Harry Potter"
"movies similar to Star Wars"
"cast of the Barbie Movie"
"chinese food park slope"
"tasty tofu dishes with peanuts"
"movies playing now"
"ai companies"

Category: 'report'
Use this for any other question.
````

### Literal at `0x103a24b70`

- Universal-file offset: `0x8c60b70`.
- Section: `__TEXT,__cstring`.
- Length: 24 bytes, without the terminating zero.

````text
AskArc/AskArcStore.swift
````

## 2. Prompts not recovered

No complete Tidy Tabs grouping prompt was identified in the selected ARM64 sections of the main executable or ArcCore. The search included prompt, title, download, summary, category, organization, question, JSON, and provider terms. It did not decode arbitrary compressed resources or recover server-side text.

`PrivateContentDetectionSystemPromptDynamic` and `PrivateContentDetectionSystemPromptStatic` are type-name candidates. Their prompt bodies were not recovered.

No absence claim is made for the full app, other architectures, remote configuration, or services. See the analysis and follow-up plan before reusing any template.
