# Multi-image attachments — 0.4.1

The one-image restriction was client-side: the composer bound PhotosPicker to a single optional item, stored one Data value per session and built only one image part.

## New behavior

- Native PhotosPicker uses an ordered array selection. The current host projection permits **20 images per message**; the picker caps selection at the remaining slots.
- Each completed batch appends to existing attachments. Reopening the picker does not replace the earlier photos. Duplicates are allowed intentionally if the same photo is chosen again.
- A horizontal native preview strip shows each photo and its own Remove button. Removing one leaves the rest in order. Drafts are session-specific; navigating to another chat does not mix the photo sets.
- Sequential ImageIO preparation bounds peak memory, honors projected dimension/pixel limits and strips source EXIF/GPS metadata from the new JPEG. Canceling stops remaining loads while retaining completed photos. Invalid photos are reported rather than silently replacing good ones.
- Send creates one immutable ordered text+image payload. Base64 and JSON body encoding run off-main. Explicit retries retain the same request ID and every image; changing order/content changes the fingerprint. The next editable draft remains separate.

## Limits

The host currently reports 20 MB per image, 20 images per message, 200 MB combined, 64 million pixels and 8192px dimensions. The mobile client deliberately bounds prepared JPEGs to **1600px, 8 MB per photo and 32 MB combined**, or a smaller host-projected limit. These are host attachment-service limits, not a claim that every selected model/provider supports vision. Provider compatibility remains validated by the Mac.

Count, per-image bytes and combined bytes are checked again before admission. A rejected limit check preserves the draft/attachments. The image-only case is supported. A live model request is not invoked automatically by tests.

## Validation

Pure checks cover ordered append, additive batches, individual removal, cancel-generation safety, per-session storage, count/byte limits and fingerprint boundaries/order. Scripted store tests verify every image is present in the outgoing content, exact retry payload/ID retention and rejection without sending/clearing the draft.

Native UI tests exercise preview/removal/navigation and the actual system picker with synthetic images in the dedicated simulator. Apple’s new Photos UI exposes image tiles rather than collection cells; test interaction uses the image tile centers and validates final composer counts. Check the release result log for actual executed cases; a focused runner once returned success with zero cases and is not accepted as evidence.

No phone Photos library was read by the agent, no user photo was copied into fixtures, and no real model/approval action was invoked. Draft/photo/outbox data remains memory-only across process termination; send or save unsent work before a development update restarts the app.
