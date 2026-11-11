
//localStorage.setItem("playedPictureGame", "no");
//localStorage.setItem("playedPictureGame", "no");

// localStorage.setItem("lastDatePlayed", null)

let lastDatePlayed = localStorage.getItem("lastDatePlayed");
//let currentDate = "2026-11-12"


// Source - https://stackoverflow.com/a/4929629
// Posted by Samuel Meddows, modified by community. See post 'Timeline' for change history
// Retrieved 2026-11-11, License - CC BY-SA 4.0
let today = new Date();
let dd = String(today.getDate()).padStart(2, '0');
let mm = String(today.getMonth() + 1).padStart(2, '0'); //January is 0!
let yyyy = today.getFullYear();

currentDate = yyyy + '-' + mm + '-' + dd;
//currentDate = "2026-11-12";



function resetPlayedDaily() {
    
    console.log(`currentDate: ${currentDate}`)
    console.log(`lastDatePlayed: ${lastDatePlayed}`)

    if(lastDatePlayed !== currentDate) {
        console.log("new day")
        //console.log(currentDate)
        localStorage.setItem("playedPictureGame", false);
        localStorage.setItem("playedGamedle", false);
        //localStorage.setItem("lastDatePlayed", null)

    }
}

resetPlayedDaily()