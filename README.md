SOLUTION OVERVIEW

 

Onco Field Agent is a unified mobile-first solution built natively on Salesforce Health Cloud, Agentforce, and Einstein. It combines voice-driven data capture, AI-generated summaries, agent-powered record creation, and a WhatsApp conversational channel to remove friction from the end-to-end post-visit workflow.

 

The solution operates across two channels:

 

1. Salesforce Mobile App and Desktop interface, used by authenticated field reps
2. WhatsApp inbound messages, processed via Meta Cloud API and routed through a dedicated Service Agent

 

A two-agent architecture supports both channels. An Employee Agent handles authenticated user requests in the mobile and desktop interface, while a Service Agent handles WhatsApp messages in a Site Guest User context. This design overcomes Salesforce's Guest User license restrictions on Einstein Copilot while preserving full data access for in-org users.

 
KEY CAPABILITIES

 
1. Voice-to-record visit logging on mobile with live transcript display
2. AI extraction of doctor, facility, visit notes, follow-up tasks, and expenses from a single utterance
3. AI-generated third-person visit summaries written in CRM-appropriate tone
4. Suggestion cards for one-tap creation of Visit, Task, and Expense records
5. Conversational disambiguation when multiple doctors or facilities match
6. Agent-powered Visit, Task, and Expense automation with active session reuse
7. Read-only Record Summary and History topic for natural-language reporting
8. End-to-end WhatsApp integration including session lifecycle, deduplication, and authorization
9. WhatsApp receipt upload — attach an image, document, or PDF and the agent automatically creates an Expense record
10. Inline summary editing with re-extraction of suggestion cards
11. Indian-locale defaults including INR currency, en_IN formatting, and DD/MM/YYYY dates

DATA MODEL


The solution uses a combination of standard Salesforce objects and custom objects designed specifically for the field sales workflow.


PERSON ACCOUNTS — REPRESENT DOCTORS


Person Accounts represent referring physicians and clinicians. The standard Account object is enabled for Person Accounts, allowing each doctor to be stored as a single record that combines Account and Contact data. Doctor names, specialties, contact details, and salutations are all captured at the Person Account level. The agent's record lookup logic resolves doctor mentions in natural language to Person Accounts using a token-based search with fallback, supporting partial names, salutation stripping, and phone-number narrowing.

BUSINESS ACCOUNTS — REPRESENT FACILITIES


Business Accounts represent hospitals, clinics, diagnostic centres, and other healthcare facilities. Each Business Account stores facility name, type, billing city, and address details. The agent identifies facility mentions like "Apollo Mumbai" or "City Care Clinic" and resolves them to the correct Business Account using keyword anchoring and noise-word stripping (the, a, hospital, clinic, medical, centre).


DOCTOR AFFILIATION — DOCTOR-FACILITY JUNCTION

A junction object captures the many-to-many relationship between doctors and facilities. One doctor can practice at multiple clinics; one clinic can host many doctors. Each affiliation record holds a Doctor lookup, a Facility lookup, and an Active flag. The agent uses this junction for facility-narrowed doctor searches (for example, "Dr. Sharma at Apollo") and to display affiliation context in record summaries.
 
VISIT — REPRESENTS A SALES REP'S FIELD VISIT


The primary record for capturing a sales rep's interaction with a referring physician. Each Visit record links to the Doctor (Person Account), the Facility (Business Account), the Sales Rep (User), and contains visit notes, audio transcript, visit type, status, and visit date. A configurable Field Set drives the cards rendered in the mobile app's Recent Visits list, allowing administrators to add or remove fields without code changes.

 
TASK — REPRESENTS A FOLLOW-UP ACTION


The standard Salesforce Task object is used for follow-up actions linked to a doctor. The agent creates Tasks via the Task Automation flow, populating the Related-To field with the doctor's Person Account, ownership with the running user, status as "Not Started", and a parsed natural-language due date.


EXPENSE AND EXPENSE LINE ITEM — REPRESENT EXPENSES


The Expense object stores expense records linked to a Visit. Fields include Total Amount Spent (currency in INR), Expense Type picklist, Vendor or Store name, Receipt or Invoice number, Transaction Date, and Description. The Expense Line Item child object captures itemized line items when a receipt is uploaded and parsed by AI (one expense to many line items, with Amount and Name per row).

 
WHATSAPP SESSION — TRACKS A WHATSAPP CONVERSATION

 

Represents an open conversation with a single WhatsApp user. Each session record holds the user's phone number, the active Agentforce session reference (so multi-turn context is preserved), the resolved Sales Rep User as record owner, last activity timestamp, status (Active, Idle, Closed), and the user's WhatsApp profile name. Sessions auto-expire after 30 minutes of inactivity to control cost and avoid carrying state forever. A formula field renders the raw international phone number into a human-readable format like (+91) 7584865889 by detecting one of fifteen supported country code prefixes.


WHATSAPP MESSAGE — LOGS EVERY INBOUND AND OUTBOUND MESSAGE

Captures the full audit trail of WhatsApp communication. Each record holds a look up to the parent session, message direction (Inbound or Outbound), message body, message type (Text, Image, Audio, Video, Document, Interactive), Meta-assigned message Id (used as an external Id for deduplication when Meta retries webhook delivery), media URL, status (Received, Sent, Delivered, Read, Failed), and error message. The object enables full message history reporting and provides the foundation for any future analytics on conversation quality.
 
MOBILE AND DESKTOP APPLICATION


The solution is delivered as a custom Lightning App named "Onco Field Agent" with phone form factor enabled. The app is structured into five tabs.

 
TAB 1 — DASHBOARD


The Dashboard is the home tab, designed for at-a-glance situational awareness and rapid action launching.


Stats grid (2x2):
- Visits this week
- Visits this month
- Open tasks
- Expenses this month, formatted in Indian numerals (Rs. 2.5L for 2,50,000)

 

Quick actions, three rows of two buttons each:
- Log Visit, navigates to the Visits tab and starts voice recording
- My Visits, opens the Visit list view
- Log Expense, opens the new Expense page
- My Expenses, opens the Expense list view
- New Task, opens the new Task page
- All Tasks, opens the Task list view

 

The dashboard auto-refreshes when the user returns to the tab, ensuring stats reflect the most recent activity.

 

 

TAB 2 — VISITS
 

The Visits tab is the heart of the field experience. It hosts the Visit Logger and a Recent Visits panel.

 

State 1 — Default
The user sees a single large voice record button with a microphone icon. A subtitle reads "Tap to speak. AI will log it." Below it, the most recent three Visit records are shown as compact cards driven by a configurable Field Set, so administrators can change which fields are displayed without code edits.

 

State 2 — Recording
On tap, the device enters recording state. The user sees a pulsing red stop button, an elapsed timer, and a live transcript that streams as they speak. The Web Speech Recognition API powers this, configured for Indian English (en-IN) with continuous restart logic to handle Android browser quirks. The user can cancel at any time.

 

State 3 — Review
On stop, the transcript is sent to AI and a structured response is returned that contains:
- A clean third-person summary written from the rep's perspective
- Doctor name and facility name with salutations stripped
- Visit date in both human-readable and ISO format
- Follow-up task subject and due date if mentioned
- Expense type, amount, and description if mentioned
- Pre-built description text for each suggestion card

 

The review screen displays:
- A read-only Visit transcript card
- An AI-generated summary card with a green AI badge and a pencil icon for inline editing
- One to three suggestion cards (Visit, Task, Expense), each with a colored side border, an icon, a title, a description, and contextual chips like "Doctor: Sharma" or "Amount: Rs. 4000"

 

When the user edits the summary inline, a separate AI step re-extracts entities from the edited text without rewriting the summary. The cards refresh while keeping the user's edited summary intact.

 

Two action buttons appear at the bottom of the review screen:
- Record Another, which clears the current transcript and starts a fresh recording session immediately. This supports the common field workflow of logging multiple visits in succession after returning to the car or office.
- Finish, which clears the review state and returns the user to the default Visits screen, refreshing the Recent Visits panel.

 

 

-------------------------------------------------------------------------------
TAB 3 — TASKS
-------------------------------------------------------------------------------

 

Standard Salesforce Task list, used for follow-ups created by the agent or manually.

 

 

-------------------------------------------------------------------------------
TAB 4 — EXPENSES
-------------------------------------------------------------------------------

 

Standard Salesforce Expense list, used for expense records created via voice, agent conversation, or receipt upload.

 

 

-------------------------------------------------------------------------------
TAB 5 — MENU
-------------------------------------------------------------------------------

 

Standard Salesforce mobile app menu.

 

 

===============================================================================
SUGGESTION CARDS — THE BRIDGE BETWEEN VOICE AND AGENT
===============================================================================

 

When a transcript is processed, the Visit Logger builds up to three suggestion cards based on what entities the AI extracted. Each card is tappable and serves as a contextual entry point into the Agent chat modal.

 

Visit suggestion card (always shown):
- Side border: green
- Description shows doctor and facility, or a fallback prompt
- Chips display extracted Doctor, Place, and Visit Date

 

Task suggestion card (shown only if a task was extracted):
- Side border: purple
- Description shows the task subject
- Chips display Doctor and Due date

 

Expense suggestion card (shown only if an expense was extracted):
- Side border: amber
- Description shows the expense purpose
- Chips display Name, Amount, and Type

 

When tapped, the card constructs a structured multi-line utterance that is passed directly to the Agent chat modal. For a Visit card, the utterance might read:

 

   Help me log a Visit with below details
   Doctor: Dr. Rajesh Sharma
   Facility: Onco Global Hospital Mumbai
   Visit Date: 03/05/2026
   Visit Notes: Met with Dr. Sharma to discuss the Q3 oncology referral pipeline...

 

The Agent receives this utterance, identifies the Doctor and Facility records, prompts the user to disambiguate if multiple matches exist, and creates the Visit record on confirmation. The same flow applies to Task and Expense cards.

 

 

===============================================================================
AGENT CHAT MODAL
===============================================================================

 

The Agent chat modal opens as a bottom sheet that defaults to 75 dynamic viewport height for native keyboard adaptation. A toggle button expands it to full screen. On tablet and desktop the sheet centers horizontally with a maximum width of 540 pixels.

 

Header elements:
- Agent avatar and name
- Active or Inactive status indicator with green or grey dot, driven by a real-time Bot Version status check
- Expand and Close buttons

 

Conversation area:
- User messages bubble right with the user's first name above them
- Agent messages bubble left with the agent name above them
- Typing indicator with three animated dots while waiting
- Disambiguation responses are parsed for an OPTIONS block, presented as a numbered list with tappable buttons

 

Input bar:
- Text input field
- Microphone button for voice input with live transcript
- Send button that disables while loading

 

The modal is lazily mounted only when needed, preserving session context across reopens through a persisted Agent session reference maintained at the parent component.

 

 

===============================================================================
AGENT CAPABILITIES
===============================================================================

 

Both the Employee Agent and the Service Agent share three topic areas: Visit and Task Automation, Expense Automation, and Record Summary and History. All topics are deployed as global assets in the Agentforce Asset Library and reused across agents.

 

 

-------------------------------------------------------------------------------
TOPIC — VISIT AND TASK AUTOMATION
-------------------------------------------------------------------------------

 

This topic handles Visit and Task creation requests in natural language, including:
- "Help me log a visit with Dr. Mehta at Apollo today"
- "Create a follow-up task to call Dr. Sharma next Monday"
- Combinations of both in a single utterance

 

Behind the scenes:
- A scope-locking step classifies the user's intent to prevent the agent from creating extra records the user did not ask for
- A keyword-anchored extraction step pulls doctor name, facility name, dates, and free-text notes from the user message
- A single record-lookup call resolves the doctor and facility using token-based search with fallback, supports phone-number narrowing, and uses the Doctor Affiliation junction object for facility-narrowed lookups
- Multi-match results are presented as a numbered list using a custom OPTIONS protocol that the chat modal renders as buttons
- The Visit Automation flow creates the Visit record with the running user as Sales Rep
- The Task Automation flow creates the Task with the doctor's Account as the Related-To field
- Confirmations include the created record's name and a one-line summary

 

 

-------------------------------------------------------------------------------
TOPIC — EXPENSE AUTOMATION
-------------------------------------------------------------------------------

 

This topic handles Expense creation requests, including conversational expense logging and receipt-based extraction. It supports:
- "Log an expense of Rs. 2000 for lunch with Dr. Priya"
- WhatsApp messages with an attached receipt image, PDF, or document — the agent automatically extracts vendor name, transaction date, invoice number, total amount, expense type, and individual line items, then creates one Expense parent record with one or more Expense Line Item children

 

The receipt extraction pipeline downloads the file from Meta's media endpoint, attaches it as a file in Salesforce, parses it through an AI-powered extraction step, and creates the structured Expense records — all without any manual typing from the user. This dramatically reduces reimbursement cycle time for field reps.

 

 

-------------------------------------------------------------------------------
TOPIC — RECORD SUMMARY AND HISTORY
-------------------------------------------------------------------------------

 

This topic handles read-only history queries about a specific Doctor or Facility, including:
- "Tell me about Dr. Rajesh Sharma"
- "How many visits did I have with Dr. Mehta this year?"
- "How much have I spent on Dr. Kavita Gupta?"
- "Recap of City Care Clinic this week"
- "When did I last visit Apollo Hospital?"
- "Tell me everything about Onco Global Hospital Mumbai"

 

Behind the scenes:
- A subject resolution step identifies whether the user is asking about a Person Account (Doctor) or Business Account (Facility), with automatic fallback if the first attempt fails
- A time-window mapping step translates phrases like "recent", "this quarter", "all time", or "last 60 days" into one of seven supported time windows (Last 7 Days, Last 30 Days, Last Month, This Quarter, This Year, All Time, Custom Days)
- A Get Record Summary action returns hybrid output: accurate aggregate counts (so "how many visits" is always correct) plus the top 10 most recent records in narrative form
- A response-formatting step renders the result as plain text safe for both Lightning chat and WhatsApp, with strict section omission rules (no "Expenses: 0" leakage), DD/MM/YYYY dates, and Rs. currency format
- Quantitative questions receive brief direct answers while general summaries receive structured multi-section output
- The topic ends conversation cleanly without proactive follow-up offers

 

For the Service Agent specifically, an additional authorization step verifies the WhatsApp sender's identity by matching their reply against User records using name, phone, email, or username, before exposing any personal CRM history. The verification state persists across the conversation so the user is asked only once.

 

 

===============================================================================
WHATSAPP INTEGRATION
===============================================================================

 

The WhatsApp channel allows field reps to interact with the agent from outside the Salesforce app, useful when on the road, during quick check-ins, or when the mobile app is not available.

 

Architecture:
- A Salesforce Site exposes a public webhook endpoint running under a dedicated Site Guest User
- Meta Cloud API delivers inbound messages via webhook POST
- The webhook handler deduplicates, sectionizes, logs the inbound message, and returns HTTP 200 within Meta's 5-second timeout
- The Service Agent invocation and outbound reply happen asynchronously to avoid the "uncommitted work pending" error when mixing data writes with callouts

 

Session lifecycle:
- A WhatsApp Session record represents an open conversation
- Sessions are reused for 30 minutes of inactivity, then closed
- Session ownership is automatically set to the resolved Sales Rep by phone-number match

 

Message logging:
- Every inbound and outbound message is logged with full audit trail
- Direction, message type, body, status, error details, and Meta-assigned message Id are all captured
- A formula field renders the raw international phone number into a human-readable display format

 

Disambiguation on WhatsApp:
- The custom OPTIONS protocol from the Agent chat modal is automatically converted to plain numbered text on WhatsApp
- Users reply with the option number, and the agent processes the choice transparently

 

Media and receipt handling:
- Image, PDF, and document attachments are downloaded from the Meta media endpoint and attached as files in Salesforce
- For expense receipts, the agent's Expense Automation topic kicks in automatically — extracting vendor, dates, invoice numbers, totals, and line items, and creating Expense and Expense Line Item records without any typed input from the user

 

 

===============================================================================
TECHNICAL HIGHLIGHTS
===============================================================================

 

Backend layer:
- Centralized constants for all org-wide string literals, eliminating magic strings
- Asynchronous callout pattern to comply with Salesforce's mixed-DML restriction
- Site Guest User SOQL runs in System Mode where required
- Token-based lookup search with intersection-first and union-fallback for ambiguous queries
- Hybrid aggregate plus detail output strategy for the Record Summary action, ensuring "how many" answers are accurate even when only the top 10 records are listed
- Defensive parsing with non-breaking-space and BOM stripping for AI JSON outputs
- Salutation stripping and duplicate "Dr." collapsing for clean record fields

 

Frontend layer:
- Mobile-first responsive design with dynamic viewport height units for keyboard adaptation
- Memorized parsing logic for agent message OPTIONS rendering
- Lazy-mounted modal for performance
- Salesforce Lightning Design System tokens with custom Onco brand variables

 

AI layer:
- Two prompt templates running on GPT 4o Mini for speed and JSON reliability
- Third-person summary generation using the running user's first name as subject
- INR currency standardization
- Dual date format output: DD-MMM-YYYY for human readability, ISO 8601 for backend
- Structured JSON parsing with code-fence stripping

 

Agentforce layer:
- Two agents (Employee and Service) sharing topics via Asset Library
- Three global topics: Visit and Task Automation, Expense Automation, Record Summary and History
- Agent-side instructions with explicit step markers and case branching
- Context variables for cross-turn state
- Strict scope locking to prevent agent over-reach

 

 

===============================================================================
ARCHITECTURE DECISIONS
===============================================================================

 

Two-agent architecture:
The Service Agent runtime bypasses the Guest User License restriction on Einstein Copilot, which would otherwise return HTTP 412 Precondition Failed for any Employee Agent invocation from the WhatsApp webhook context. This decision is the foundation of the WhatsApp integration's reliability.

 

Custom chat modal:
There is no documented, supported way to programmatically open the embedded Agentforce assistant panel and auto-send an utterance from a custom component running in a standard Lightning App. Therefore the project implements a custom chat modal that calls the agent directly and renders the conversation in its own UI.

 

Lookup over Master-Detail:
The WhatsApp Message object uses a Lookup relationship to the WhatsApp Session object rather than Master-Detail because Master-Detail inserts under Guest User context throw a cross-reference access error.

 

Permanent Meta token:
A System User token is generated from Meta Business Suite and configured to never expire, avoiding the 24-hour token rotation that would otherwise break the integration daily.

 

 

===============================================================================
TARGET USERS AND BUSINESS IMPACT
===============================================================================

 

Primary users:
- 22 field sales executives at Onco Global, distributed across India

 

Pain points addressed:
- Hours per week spent on manual visit logging are eliminated through voice capture and AI extraction
- Spreadsheet and phone-call relationship tracking is replaced with structured CRM records
- Mobile typing friction is replaced with conversational voice input
- ROI on outreach is now measurable through the Record Summary topic
- Receipt-based expense entry on WhatsApp removes the need to type each line item manually

 

Expected outcomes:
- Higher visit completion rates due to lower data-entry friction
- Better physician relationship insights through accurate, complete history records
- Faster expense reimbursement cycles due to receipt OCR and conversational expense logging
- Improved sales rep retention through reduced administrative burden
