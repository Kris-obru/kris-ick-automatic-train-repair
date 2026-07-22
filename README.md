## Overview
If any locomotive or wagon is destroyed the train it belongs to is brought to an immediate halt and a ghost is created. This ghost contains by default requests for all fuel and equipment that was inside the destroyed rolling stock. Inventory filters and limits are saved and restored as well. As soon as the train is complete again it will be set to automatic mode, if it was in that mode originally. Multiple destroyed cars from the same consist share one repair job, so rebuild order does not matter.


## Settings
The following map settings are available:

* Automatically enable automatic mode (trains will be set to automatic mode again as soon as all entity ghosts for that incident were built). Default = true
* Create item requests for destroyed equipment. Default = true
* Create item requests for fuel. Default = true
* Name of the fuel that should be requested (if left empty the destroyed fuel type(s) will be requested). Default = empty
* How much of the fuel should be requested. Default = 0 (fill the full fuel inventory: slots × stack size; set a positive value for a fixed count)

The following player setting is available:

* Create alerts. Default = true


## Known issues
* The check whether a train is complete again does not wait for all item requests (fuel/equipment) to be fulfilled and can't tell the difference between different entities of the same type beyond position matching.
* Schedule/group/layout for every train are kept continuously in mod storage (`ick_trains`). When rolling stock is destroyed, that registry entry is looked up and re-applied after the full consist is rebuilt.
* Partial rebuilds stay manual/stopped until the repair job is complete.
* Fuel requests default to a full fuel inventory (slots × stack size).
* Rail-target-only schedule stops cannot be persisted; station stops, groups, and interrupts are restored when possible.
* If the train is allowed to keep moving with a gap (another mod overriding the stop), ghosts will not track the rolling stock.
* Equipment may still use a cargo→grid fallback for some wagon grids; prefer grid insert plans when possible.
* The item request icons in ghosts for wagons are, unlike for locomotives, not grouped.
