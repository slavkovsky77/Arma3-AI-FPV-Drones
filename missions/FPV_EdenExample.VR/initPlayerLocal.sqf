player allowDamage false;

private _text = "<t size='1.3'>FPV AI Drones - Editor example</t><br/><br/>
This is the whole editor setup - nothing else is needed:<br/><br/>
<t color='#ffd27f'>1.</t> Place drones (here: empty <t color='#ffd27f'>Crocus AT</t> and <t color='#ffd27f'>Crocus AP</t>). They don't need a crew.<br/>
<t color='#ffd27f'>2.</t> Place a module from <t color='#ffd27f'>Systems > Modules > Effects > FPV AI Drones</t>: Anti-Tank for vehicles, Anti-Personnel for infantry.<br/>
<t color='#ffd27f'>3.</t> <t color='#ffd27f'>Sync</t> the module to the drones (select the module, F5, drag to each drone).<br/><br/>
<t color='#ffd27f'>UAV Operator Required:</t> to the south, an <t color='#ffd27f'>AR-2</t> and a <t color='#ffd27f'>UAV operator</t> are both synced to an Anti-Tank module with that setting ticked. When the operator is killed, his drone comes down. In Zeus, drop the module onto a soldier instead.<br/><br/>
Enemies arrive in about 20 seconds from the east. The drones take off, spot anything hostile within 200 m, and dive into it.<br/><br/>
Press <t color='#ffd27f'>Y</t> for a Zeus camera to watch from.<br/><br/>
<t size='0.85' color='#bbbbbb'>Want to open this in the editor? Copy the mod's examples\FPV_EdenExample.VR folder into Documents\Arma 3\missions.</t>";

player createDiaryRecord ["Diary", ["FPV AI Drones - how it works", _text]];
hint parseText _text;
