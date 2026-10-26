player allowDamage false;

private _text = "<t size='1.3'>FPV AI Drones - Zeus example</t><br/><br/>
<t color='#ffd27f'>1.</t> Press <t color='#ffd27f'>Y</t> to open Zeus.<br/>
<t color='#ffd27f'>2.</t> Open <t color='#ffd27f'>Modules > Effects > FPV AI Drones</t>.<br/>
<t color='#ffd27f'>3.</t> Place the <t color='#ffd27f'>Anti-Tank</t> module - on the <t color='#7fb2ff'>blue</t> drone station, or anywhere: it takes over every <t color='#ffd27f'>Crocus AT</t> on the map. They take off and hit the tank nearby.<br/>
<t color='#ffd27f'>4.</t> Place the <t color='#ffd27f'>Anti-Personnel</t> module for the <t color='#7fff7f'>green</t> station's <t color='#ffd27f'>Crocus AP</t> drones and the infantry.<br/>
<t color='#ffd27f'>5.</t> Keep placing <t color='#ffd27f'>Crocus</t> drones at a station - they're picked up too. You can also drop a module straight onto a single drone.<br/>
<t color='#ffd27f'>6.</t> Targets further out are beyond the 200 m a drone can see: select a drone and give it a <t color='#ffd27f'>waypoint</t> towards them.<br/>
<t color='#ffd27f'>7.</t> Drop a module onto a <t color='#ffd27f'>soldier</t>: he becomes the operator of the drones within 100 m. Kill him and they come down.<br/><br/>
<t size='0.85' color='#bbbbbb'>With 'Control All Drones Of This Type' on (default), a module also takes over every other drone of the same type on the map.</t>";

player createDiaryRecord ["Diary", ["FPV AI Drones - Zeus guide", _text]];
hint parseText _text;
